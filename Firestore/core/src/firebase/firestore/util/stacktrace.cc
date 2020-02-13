/*
 * Copyright 2020 Google LLC
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

#include "Firestore/core/src/firebase/firestore/util/stacktrace.h"

#include <execinfo.h>

#include "absl/strings/str_cat.h"

namespace firebase {
namespace firestore {
namespace util {

std::string GetStackTrace(int skip) {
  constexpr int max_frames = 128;

  // Skip the GetStackTrace frame plus any others that the caller wants to get
  // rid of.
  skip += 1;

  void* call_stack[max_frames];
  int frames = backtrace(call_stack, max_frames);

  char** lines = backtrace_symbols(call_stack, frames);

  std::string result;
  for (int i = skip; i < frames; ++i) {
    if (i > 0) {
      absl::StrAppend(&result, "\n");
    }
    absl::StrAppend(&result, lines[i]);
  }
  free(lines);

  return result;
}

}  // namespace util
}  // namespace firestore
}  // namespace firebase
