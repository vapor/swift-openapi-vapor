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
import Testing
import Vapor

@testable import OpenAPIVapor

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct AbortExtensionsTests {
    @Test
    func conversion() async throws {
        let error = Abort(.unauthorized) as any HTTPResponseConvertible
        #expect(error.httpStatus == .unauthorized)
        #expect(
            error.httpHeaderFields == [
                .contentType: "application/json"
            ])
        let body = try #require(error.httpBody)
        let bodyString = try await String(collecting: body, upTo: 1024)
        struct ExpectedValue: Decodable, Equatable {
            var status: Int
            var title: String
        }
        let decoded = try JSONDecoder().decode(ExpectedValue.self, from: Data(bodyString.utf8))
        #expect(decoded == ExpectedValue(status: 401, title: "401: Unauthorized"))
    }
}
