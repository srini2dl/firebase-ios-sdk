/*
 * Copyright 2019 Google
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

#include "Firestore/core/src/firebase/firestore/api/snapshots_in_sync_listener_registration.h"

#include <utility>

#include "Firestore/core/src/firebase/firestore/core/firestore_client.h"

namespace firebase {
namespace firestore {
namespace api {

SnapshotsInSyncListenerRegistration::SnapshotsInSyncListenerRegistration(
    std::shared_ptr<core::FirestoreClient> client,
    std::shared_ptr<core::EventListener<util::Empty>> listener)
    : client_(std::move(client)), listener_(std::move(listener)) {
}

void SnapshotsInSyncListenerRegistration::Remove() {
  auto listener = listener_.lock();
  if (listener) {
    listener->Mute();

    auto client = client_.lock();
    if (client) {
      client->RemoveSnapshotsInSyncListener(listener);
      client_.reset();
    }

    listener_.reset();
  }
}

}  // namespace api
}  // namespace firestore
}  // namespace firebase
