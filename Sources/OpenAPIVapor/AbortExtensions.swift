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
import NIOHTTPTypesHTTP1
import OpenAPIRuntime
import Vapor

// This @retroactive conformance is okay as it assumes that Vapor v4 will never gain
// a direct dependency on Swift OpenAPI Runtime.
// swift-format-ignore: AvoidRetroactiveConformances
extension Abort: @retroactive HTTPResponseConvertible {
  public var httpStatus: HTTPResponse.Status {
    .init(code: Int(status.code))
  }

  public var httpHeaderFields: HTTPTypes.HTTPFields {
    var headerFields: HTTPTypes.HTTPFields = .init(headers, splitCookie: false)
    headerFields[.contentType] = "application/json"
    return headerFields
  }

  public var httpBody: OpenAPIRuntime.HTTPBody? {
    let problem = JSONProblem(
      title: "\(identifier): \(reason)",
      status: Int(status.code)
    )
    guard let data = try? jsonEncoder.encode(problem) else {
      // We don't have a great place to communicate an encoding error here.
      return nil
    }
    return .init(data)
  }
}

private let jsonEncoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
  return encoder
}()

// https://datatracker.ietf.org/doc/html/rfc7807#section-3.1
private struct JSONProblem: Encodable {
  var type: URI?
  var title: String?
  var status: Int?
  var detail: String?
  var instance: URI?
}
