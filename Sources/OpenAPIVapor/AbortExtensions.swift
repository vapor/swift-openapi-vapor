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

public import HTTPTypes
public import OpenAPIRuntime
public import Vapor

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// This @retroactive conformance is okay as it assumes that Vapor v5 will never gain
// a direct dependency on Swift OpenAPI Runtime.
// swift-format-ignore: AvoidRetroactiveConformances
extension Abort: @retroactive HTTPResponseConvertible {
    public var httpStatus: HTTPResponse.Status {
        status
    }

    public var httpHeaderFields: HTTPTypes.HTTPFields {
        var headers = headers
        headers[.contentType] = "application/json"
        return headers
    }

    public var httpBody: OpenAPIRuntime.HTTPBody? {
        let problem = JSONProblem(
            title: "\(identifier): \(reason)",
            status: Int(status.code)
        )
        var buffer = Data()
        var headers = HTTPFields()
        do {
            if let encoder = try? ContentConfiguration.default().requireEncoder(for: .json) {
                try encoder.encode(problem, to: &buffer, headers: &headers, userInfo: [:])
            } else {
                try fallbackJSONEncoder.encode(problem, to: &buffer, headers: &headers, userInfo: [:])
            }
        } catch {
            // We don't have a great place to communicate an encoding error here.
            return nil
        }
        return .init(buffer)
    }
}

private let fallbackJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return encoder
}()

// A subset of https://datatracker.ietf.org/doc/html/rfc7807#section-3.1
private struct JSONProblem: Encodable {
    var title: String
    var status: Int
}
