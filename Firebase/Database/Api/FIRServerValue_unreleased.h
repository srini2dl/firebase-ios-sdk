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

#ifndef FIRServerValue_unreleased_h
#define FIRServerValue_unreleased_h

#import "FIRServerValue.h"

@interface FIRServerValue (Unreleased)

/**
 * Adds the given delta to the ref's current value.
 *
 * This must be an long or a double value. If the ref is not an integer or
 * double, or if the ref does not yet exist, the transformation will set the ref
 * to the given value. If either of the given value or the current field value
 * are doubles, both values will be interpreted as doubles. Double arithmetic
 * and representation of double values follow IEEE 754 semantics. If there is
 * positive/negative integer overflow, the field is resolved to a double.
 * @param delta the amount to modify the ref's current value atomically.
 * @return a placeholder value for modifying a ref atomically server-side.
 */
+ (NSDictionary *)increment:(NSNumber *)delta NS_SWIFT_NAME(increment(_:));

@end

#endif /* FIRServerValue_unreleased_h */