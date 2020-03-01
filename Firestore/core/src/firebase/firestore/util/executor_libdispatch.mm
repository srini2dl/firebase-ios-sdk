/*
 * Copyright 2018 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "Firestore/core/src/firebase/firestore/util/executor_libdispatch.h"

#include <mutex>  // NOLINT(build/c++11)

#include "Firestore/core/src/firebase/firestore/util/log.h"
#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"
#include "Firestore/core/src/firebase/firestore/util/stacktrace.h"

namespace firebase {
namespace firestore {
namespace util {

namespace {

absl::string_view StringViewFromDispatchLabel(const char* const label) {
  // Make sure string_view's data is not null, because it's used for logging.
  return label ? absl::string_view{label} : absl::string_view{""};
}

// GetLabel functions are guaranteed to never return a "null" string_view
// (i.e. data() != nullptr).
absl::string_view GetQueueLabel(const dispatch_queue_t queue) {
  return StringViewFromDispatchLabel(dispatch_queue_get_label(queue));
}
absl::string_view GetCurrentQueueLabel() {
  // Note: dispatch_queue_get_label may return nullptr if the queue wasn't
  // initialized with a label.
  return StringViewFromDispatchLabel(
      dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL));
}

}  // namespace

class PendingOperation {
 public:
  PendingOperation(ExecutorLibdispatch* executor, const char* what)
      : executor_(executor), what_(what) {
    stacktrace_ = util::GetStackTrace(0);
    executor_->EnterGroup(this);
  }

  virtual ~PendingOperation() {
    executor_->LeaveGroup(this);
  }

  const char* what() const {
    return what_;
  }

  const std::string& stacktrace() const {
    return stacktrace_;
  }

 private:
  ExecutorLibdispatch* executor_;
  const char* what_;
  std::string stacktrace_;
};

// MARK: - TimeSlot

// Represents a "busy" time slot on the schedule.
//
// Since libdispatch doesn't provide a way to cancel a scheduled operation, once
// a slot is created, it will always stay in the schedule until the time is
// past. Consequently, it is more useful to think of a time slot than
// a particular scheduled operation -- by the time the slot comes, operation may
// or may not be there (imagine getting to a meeting and finding out it's been
// canceled).
//
// Precondition: all member functions, including the constructor, are *only*
// invoked on the Firestore queue.
//
//   Ownership:
//
// - `TimeSlot` is exclusively owned by libdispatch;
// - `ExecutorLibdispatch` contains non-owning pointers to `TimeSlot`s;
// - invariant: if the executor contains a pointer to a `TimeSlot`, it is
//   a valid object. It is achieved because when libdispatch invokes
//   a `TimeSlot`, it always removes it from the executor before deleting it.
//   The reverse is not true: a canceled time slot is removed from the executor,
//   but won't be destroyed until its original due time is past.

class TimeSlot : public PendingOperation {
 public:
  TimeSlot(ExecutorLibdispatch* executor,
           Executor::Milliseconds delay,
           Executor::TaggedOperation&& operation,
           Executor::Id slot_id);

  ~TimeSlot();

  bool is_done() {
    return done_;
  }

  // Returns the operation that was scheduled for this time slot and turns the
  // slot into a no-op.
  Executor::TaggedOperation RemoveOperation();

  // Marks the TimeSlot done.
  void MarkDone();

  bool operator<(const TimeSlot& rhs) const {
    // Order by target time, then by the order in which entries were created.
    if (target_time_ < rhs.target_time_) {
      return true;
    }
    if (target_time_ > rhs.target_time_) {
      return false;
    }

    return time_slot_id_ < rhs.time_slot_id_;
  }
  bool operator==(const Executor::Tag tag) const {
    return tagged_.tag == tag;
  }

  static void InvokedByLibdispatch(void* raw_self);

 private:
  void MarkDoneLocked();
  void Execute();
  void RemoveFromScheduleLocked();

  using TimePoint = std::chrono::time_point<std::chrono::steady_clock,
                                            Executor::Milliseconds>;

  ExecutorLibdispatch* executor_;
  const TimePoint target_time_;  // Used for sorting
  Executor::TaggedOperation tagged_;
  Executor::Id time_slot_id_ = 0;

  // True if the operation has either been run or canceled.
  //
  // Note on thread-safety: this variable is accessed both from the dispatch
  // queue and in the destructor, which may run on any queue.
  std::mutex mutex_;
  bool done_ = false;
};

TimeSlot::TimeSlot(ExecutorLibdispatch* executor,
                   const Executor::Milliseconds delay,
                   Executor::TaggedOperation&& operation,
                   Executor::Id slot_id)
    : PendingOperation(executor, "TimeSlot"),
      executor_{executor},
      target_time_{std::chrono::time_point_cast<Executor::Milliseconds>(
                       std::chrono::steady_clock::now()) +
                   delay},
      tagged_{std::move(operation)},
      time_slot_id_{slot_id} {
}

TimeSlot::~TimeSlot() {
  HARD_ASSERT_NOTHROW(done_);
}

Executor::TaggedOperation TimeSlot::RemoveOperation() {
  std::lock_guard<std::mutex> lock(mutex_);

  MarkDoneLocked();
  return std::move(tagged_);
}

void TimeSlot::MarkDone() {
  std::lock_guard<std::mutex> lock(mutex_);
  MarkDoneLocked();
}

void TimeSlot::InvokedByLibdispatch(void* raw_self) {
  auto const self = static_cast<TimeSlot*>(raw_self);
  self->Execute();
  delete self;
}

void TimeSlot::MarkDoneLocked() {
  if (!done_) {
    executor_->LeaveGroup(this);
  }
  done_ = true;
}

void TimeSlot::Execute() {
  std::lock_guard<std::mutex> lock(mutex_);

  if (done_) {
    // `done_` might mean that the executor is already destroyed, so don't call
    // `RemoveFromScheduleLocked`.
    return;
  }

  HARD_ASSERT(tagged_.operation,
              "TimeSlot contains an invalid function object");
  tagged_.operation();

  RemoveFromScheduleLocked();
}

void TimeSlot::RemoveFromScheduleLocked() {
  MarkDoneLocked();
  executor_->RemoveFromSchedule(time_slot_id_);
}

// MARK: - GroupGuard

class GroupGuardedOperation : public PendingOperation {
 public:
  GroupGuardedOperation(ExecutorLibdispatch* executor, const char* what, Executor::Operation&& operation)
      : PendingOperation(executor, what), operation_(std::move(operation)) {
  }

  void Invoke() {
    operation_();
  }

 private:
  Executor::Operation operation_;
};

// MARK: - ExecutorLibdispatch

ExecutorLibdispatch::ExecutorLibdispatch(const dispatch_queue_t dispatch_queue)
    : group_(dispatch_group_create()), queue_{dispatch_queue} {
}

ExecutorLibdispatch::~ExecutorLibdispatch() {
  Dispose();
}

void ExecutorLibdispatch::Dispose() {
  std::lock_guard<std::mutex> lock(mutex_);

  // Turn any operations that might still be in the queue into no-ops, lest
  // they try to access `ExecutorLibdispatch` after it gets destroyed. Because
  // the queue is serial, by the time libdispatch gets to the newly-enqueued
  // work, the pending operations that might have been in progress would have
  // already finished.
  // Note: this is thread-safe, because the underlying variable `done_` is
  // atomic. `DispatchSync` may result in a deadlock.
  for (const auto& entry : schedule_) {
    entry.second->MarkDone();
  }

  LOG_DEBUG("Executor(%s): Awaiting group: %s (outstanding: %s)",
            this, GetCurrentQueueLabel(), outstanding_.size());

  for (PendingOperation* op : outstanding_) {
    LOG_DEBUG("Executor(%s): Missing from group: %s %s, %s\n\n%s\n\n",
        this, GetCurrentQueueLabel(), op, op->what(), op->stacktrace());
  }

  dispatch_group_wait(group_, DISPATCH_TIME_FOREVER);
}

bool ExecutorLibdispatch::IsCurrentExecutor() const {
  return GetCurrentQueueLabel() == GetQueueLabel(queue_);
}
std::string ExecutorLibdispatch::CurrentExecutorName() const {
  return GetCurrentQueueLabel().data();
}
std::string ExecutorLibdispatch::Name() const {
  return GetQueueLabel(queue_).data();
}

void ExecutorLibdispatch::Execute(Operation&& operation) {
  // Dynamically allocate the function to make sure the object is valid by the
  // time libdispatch gets to it.
  const auto wrap = new GroupGuardedOperation(this, "Execute", std::move(operation));

  dispatch_async_f(queue_, wrap, [](void* const raw_work) {
    const auto unwrap = static_cast<GroupGuardedOperation*>(raw_work);
    unwrap->Invoke();
    delete unwrap;
  });
}
void ExecutorLibdispatch::ExecuteBlocking(Operation&& operation) {
  PendingOperation guard(this, "ExecuteBlocking");

  if (GetCurrentQueueLabel() == GetQueueLabel(queue_)) {
    // dispatch_sync_f will deadlock if you try to dispatch an operation to a
    // queue from which you're currently running.
    operation();

  } else {
    // Unlike dispatch_async_f, dispatch_sync_f blocks until the work passed to
    // it is done, so passing a reference to a local variable is okay.
    dispatch_sync_f(queue_, &operation, [](void* const raw_work) {
      const auto unwrap = static_cast<std::function<void()>*>(raw_work);
      (*unwrap)();
    });
  }
}

DelayedOperation ExecutorLibdispatch::Schedule(const Milliseconds delay,
                                               TaggedOperation&& operation) {
  namespace chr = std::chrono;
  const dispatch_time_t delay_ns = dispatch_time(
      DISPATCH_TIME_NOW, chr::duration_cast<chr::nanoseconds>(delay).count());

  // Ownership is fully transferred to libdispatch -- because it's impossible
  // to truly cancel work after it's been dispatched, libdispatch is
  // guaranteed to outlive the executor, and it's possible for work to be
  // invoked by libdispatch after the executor is destroyed. Executor only
  // stores an observer pointer to the operation.
  TimeSlot* time_slot = nullptr;
  Id time_slot_id = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);

    time_slot_id = NextId();
    time_slot = new TimeSlot{this, delay, std::move(operation), time_slot_id};
    schedule_[time_slot_id] = time_slot;
  }

  dispatch_after_f(delay_ns, queue_, time_slot, TimeSlot::InvokedByLibdispatch);

  // `time_slot` might have been destroyed by the time cancellation function
  // runs, in which case it's guaranteed to have been removed from the
  // `schedule_`. If the `time_slot_id` refers to a slot that has been
  // removed, the call to `Cancel` will be a no-op.
  return DelayedOperation(this, time_slot_id);
}

void ExecutorLibdispatch::RemoveFromSchedule(Id to_remove) {
  std::lock_guard<std::mutex> lock(mutex_);

  const auto found = schedule_.find(to_remove);

  // It's possible for the operation to be missing if libdispatch gets to run
  // it after it was force-run, for example.
  if (found != schedule_.end()) {
    HARD_ASSERT(found->second->is_done());
    schedule_.erase(found);
  }
}

void ExecutorLibdispatch::Cancel(Id to_remove) {
  std::lock_guard<std::mutex> lock(mutex_);

  const auto found = schedule_.find(to_remove);

  // It's possible for the operation to be missing if libdispatch gets to run
  // it after it was force-run, for example.
  if (found != schedule_.end()) {
    found->second->MarkDone();
    schedule_.erase(found);
  }
}

// Test-only methods

bool ExecutorLibdispatch::IsScheduled(const Tag tag) const {
  std::lock_guard<std::mutex> lock(mutex_);

  return std::any_of(schedule_.begin(), schedule_.end(),
                       [&tag](const ScheduleEntry& operation) {
                         return *operation.second == tag;
                       });
}

absl::optional<Executor::TaggedOperation>
ExecutorLibdispatch::PopFromSchedule() {
  std::lock_guard<std::mutex> lock(mutex_);

  if (schedule_.empty()) {
    return absl::nullopt;
  }

  const auto nearest = std::min_element(
      schedule_.begin(), schedule_.end(),
      [](const ScheduleEntry& lhs, const ScheduleEntry& rhs) {
        return *lhs.second < *rhs.second;
      });

  Executor::TaggedOperation operation = nearest->second->RemoveOperation();
  schedule_.erase(nearest);
  return {std::move(operation)};
}

void ExecutorLibdispatch::EnterGroup(PendingOperation* op) {
  dispatch_group_enter(group_);
  outstanding_.insert(op);
  LOG_DEBUG("Executor(%s): Enter group: %s, %s %s (outstanding: %s), %s",
      this, GetCurrentQueueLabel(), op, op->what(), outstanding_.size(),
      [group_ debugDescription]);
}

void ExecutorLibdispatch::LeaveGroup(PendingOperation* op) {
  size_t erased = outstanding_.erase(op);
  if (erased > 0) {
    dispatch_group_leave(group_);
  }
  LOG_DEBUG("Executor(%s): Leave group: %s, %s %s (outstanding: %s), %s",
      this, GetCurrentQueueLabel(), op, op->what(), outstanding_.size(),
      [group_ debugDescription]);
}

Executor::Id ExecutorLibdispatch::NextId() {
  // The wrap around after ~4 billion operations is explicitly ignored. Even if
  // an instance of `ExecutorLibdispatch` runs long enough to get `current_id_`
  // to overflow, it's extremely unlikely that any object still holds a
  // reference that is old enough to cause a conflict.
  return current_id_++;
}

// MARK: - Executor

std::unique_ptr<Executor> Executor::CreateSerial(const char* label) {
  dispatch_queue_t queue = dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
  return absl::make_unique<ExecutorLibdispatch>(queue);
}

std::unique_ptr<Executor> Executor::CreateConcurrent(const char* label,
                                                     int threads) {
  HARD_ASSERT(threads > 1);

  // Concurrent queues auto-create enough threads to avoid deadlock so there's
  // no need to honor the threads argument.
  dispatch_queue_t queue =
      dispatch_queue_create(label, DISPATCH_QUEUE_CONCURRENT);
  return absl::make_unique<ExecutorLibdispatch>(queue);
}

}  // namespace util
}  // namespace firestore
}  // namespace firebase
