//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift OpenAPI Vapor open source project
//
// Copyright (c) 2026 the Swift OpenAPI Vapor project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTPTypes
import OpenAPIRuntime
import XCTVapor

@testable import OpenAPIVapor

final class AbortExtensionsTests: XCTestCase {
  func testConversion() async throws {
    let error = Abort(.unauthorized) as any HTTPResponseConvertible
    XCTAssertEqual(error.httpStatus, .unauthorized)
    XCTAssertEqual(
      error.httpHeaderFields,
      [
        .contentType: "application/json"
      ])
    let body = try XCTUnwrap(error.httpBody)
    let bodyString = try await String(collecting: body, upTo: 1024)
    XCTAssertEqual(
      bodyString,
      """
      {
        "status" : 401,
        "title" : "401: Unauthorized"
      }
      """)
  }
}
