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

#import <FirebaseCore/FIRAppInternal.h>
#import <FirebaseCore/FIROptionsInternal.h>
#import <FirebaseFirestore/FIRFirestore.h>
#import <FirebaseFirestore/FIRFirestoreSettings.h>

#import <XCTest/XCTest.h>

#include <iostream>
#include <future>  // NOLINT(build/c++11)

#import "Firestore/Source/API/FIRFirestore+Internal.h"
#import "Firestore/Example/Tests/Util/FSTIntegrationTestCase.h"

#include "Firestore/core/src/firebase/firestore/api/document_reference.h"
#include "Firestore/core/src/firebase/firestore/api/document_snapshot.h"
#include "Firestore/core/src/firebase/firestore/core/event_listener.h"
#include "Firestore/core/src/firebase/firestore/core/listen_options.h"
#include "Firestore/core/src/firebase/firestore/util/string_apple.h"
#include "Firestore/core/src/firebase/firestore/util/statusor.h"
#include "Firestore/core/test/firebase/firestore/testutil/app_testing.h"
#include "Firestore/core/test/firebase/firestore/testutil/async_testing.h"

namespace {

namespace api = firebase::firestore::api;
namespace core = firebase::firestore::core;
namespace util = firebase::firestore::util;
namespace testutil = firebase::firestore::testutil;

using api::DocumentReference;
using api::DocumentSnapshot;
using api::Firestore;
using core::EventListener;
using core::ListenOptions;
using testutil::Async;
using testutil::Await;
using testutil::Expectation;
using testutil::SleepFor;
using util::MakeString;
using util::StatusOr;

class LockedString {
 public:
  void Append(const char* step) {
    std::lock_guard<std::mutex> lock(mutex_);
    contents_.append(step);
  }

  std::string contents() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return contents_;
  }

 private:
  mutable std::mutex mutex_;
  std::string contents_;
};

}  // namespace

@interface FIRInternalAPITests : FSTIntegrationTestCase
@end

@implementation FIRInternalAPITests {
  std::shared_ptr<Firestore> _firestore;
}

- (void)setUp {
  [super setUp];
  FIRFirestore *firestore = [self firestore];
  FIRFirestoreSettings *settings = firestore.settings;
  settings.dispatchQueue = dispatch_queue_create("firestore.testing.user", DISPATCH_QUEUE_SERIAL);
  firestore.settings = settings;

  _firestore = firestore.wrapped;
}

- (void)testFirestoreDisposal {
  NSString *path = [self documentPath];
  FIRDocumentReference *docRef = [self.db documentWithPath:path];
  [self writeDocumentRef:docRef data:@{ @"foo": @"bar" }];

  DocumentReference internalRef = _firestore->GetDocument(MakeString(path));
  LockedString events;

  Expectation userCalled;
  Expectation userProceed;
  Expectation userComplete;
  auto listener = EventListener<DocumentSnapshot>::Create(
      [&](const StatusOr<DocumentSnapshot> &maybeSnapshot) {
        userCalled.Fulfill();

        Await(userProceed);
        events.Append("2");

        userComplete.Fulfill();
      });

  internalRef.AddSnapshotListener(ListenOptions::DefaultOptions(), std::move(listener));
  Await(userCalled);

  // Asynchronously call Dispose, because it should block until the callback
  // completes.
  Expectation disposeStarting;
  Expectation disposeComplete;
  Expectation disposeProceed;
  Async([&] {
    events.Append("1");

    disposeStarting.Fulfill();
    _firestore->Dispose();

    events.Append("3");
    disposeComplete.Fulfill();
  });

  std::string actual = events.contents();
  XCTAssertEqual(events.contents(), "", @"Expected '', got '%s'", actual.c_str());
  Await(disposeStarting);
  SleepFor(50);

  // Dispose shouldn't complete because the callback to the listener has not
  // been unblocked. If you see "13" here, Dispose completed without waiting.
  actual = events.contents();
  XCTAssertEqual(events.contents(), "1", @"Expected '1', got '%s'", actual.c_str());

  userProceed.Fulfill();

  Await(userComplete);
  actual = events.contents();
  XCTAssertEqual(events.contents(), "12", @"Expected '12', got '%s'", actual.c_str());

  disposeProceed.Fulfill();
  Await(disposeComplete);
  actual = events.contents();
  XCTAssertEqual(events.contents(), "123", @"Expected '123', got '%s'", actual.c_str());
}

- (void)testFirestoreDisposalOnError {
  DocumentReference internalRef = _firestore->GetDocument("__invalid__/foo");
  LockedString events;

  Expectation userCalled;
  Expectation userProceed;
  Expectation userComplete;
  auto listener = EventListener<DocumentSnapshot>::Create(
      [&](const StatusOr<DocumentSnapshot> &maybeSnapshot) {
        userCalled.Fulfill();

        Await(userProceed);
        events.Append("2");

        userComplete.Fulfill();
      });

  internalRef.AddSnapshotListener(ListenOptions::DefaultOptions(), std::move(listener));
  Await(userCalled);

  // Asynchronously call Dispose, because it should block until the callback
  // completes.
  Expectation disposeStarting;
  Expectation disposeComplete;
  Expectation disposeProceed;
  Async([&] {
    events.Append("1");

    disposeStarting.Fulfill();
    _firestore->Dispose();

    events.Append("3");
    disposeComplete.Fulfill();
  });

  std::string actual = events.contents();
  XCTAssertEqual(events.contents(), "", @"Expected '', got '%s'", actual.c_str());
  Await(disposeStarting);
  SleepFor(50);

  // Dispose shouldn't complete because the callback to the listener has not
  // been unblocked. If you see "13" here, Dispose completed without waiting.
  actual = events.contents();
  XCTAssertEqual(events.contents(), "1", @"Expected '1', got '%s'", actual.c_str());

  userProceed.Fulfill();

  Await(userComplete);
  actual = events.contents();
  XCTAssertEqual(events.contents(), "12", @"Expected '12', got '%s'", actual.c_str());

  disposeProceed.Fulfill();
  Await(disposeComplete);
  actual = events.contents();
  XCTAssertEqual(events.contents(), "123", @"Expected '123', got '%s'", actual.c_str());
}

@end
