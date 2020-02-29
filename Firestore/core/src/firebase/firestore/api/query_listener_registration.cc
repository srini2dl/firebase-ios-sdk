/*
 * Copyright 2019 Google LLC
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

#include "Firestore/core/src/firebase/firestore/api/query_listener_registration.h"
#include "Firestore/core/src/firebase/firestore/core/firestore_client.h"

namespace firebase {
namespace firestore {
namespace api {

QueryListenerRegistration::QueryListenerRegistration(
    std::shared_ptr<core::FirestoreClient> client,
    std::shared_ptr<core::QueryListener> query_listener)
    : client_(std::move(client)),
      query_listener_(std::move(query_listener)) {
}

void QueryListenerRegistration::Remove() {
  auto query_listener = query_listener_.lock();
  if (query_listener) {
    // Synchronously dispose of the listener, to prevent events from escaping.
    query_listener->Dispose();

    auto shared_client = client_.lock();
    if (shared_client) {
      shared_client->RemoveListener(query_listener);
    }
    query_listener_.reset();
  }

  client_.reset();
}

}  // namespace api
}  // namespace firestore
}  // namespace firebase
