//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift OpenAPI Vapor open source project
//
// Copyright (c) 2023 the Swift OpenAPI Vapor project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import Foundation
import HTTPTypes
import NIOFoundationCompat
import NIOHTTPTypesHTTP1
import OpenAPIRuntime
import Vapor

public final class VaporTransport {

  /// A routes builder with which to register request handlers.
  internal var routesBuilder: any Vapor.RoutesBuilder

  /// Creates a new transport.
  /// - Parameter routesBuilder: A routes builder with which to register request handlers.
  public init(routesBuilder: any Vapor.RoutesBuilder) {
    self.routesBuilder = routesBuilder
  }
}

extension VaporTransport: ServerTransport {
  public func register(
    _ handler:
      @Sendable @escaping (
        HTTPTypes.HTTPRequest, OpenAPIRuntime.HTTPBody?, OpenAPIRuntime.ServerRequestMetadata
      ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?),
    method: HTTPRequest.Method,
    path: String
  ) throws {
    self.routesBuilder.on(
      HTTPMethod(method),
      [PathComponent](path),
      body: .stream
    ) { vaporRequest in
      let request = try HTTPTypes.HTTPRequest(vaporRequest)
      let body = OpenAPIRuntime.HTTPBody(vaporRequest)
      let requestMetadata = try OpenAPIRuntime.ServerRequestMetadata(
        from: vaporRequest,
        forPath: path
      )
      let res = try await handler(request, body, requestMetadata)
      let response = Vapor.Response(response: res.0, body: res.1)
      if let contentLength = res.0.headerFields.first(where: { $0.name == .contentLength }) {
        response.headers.replaceOrAdd(name: .contentLength, value: contentLength.value)
      }
      return response
    }
  }
}

enum VaporTransportError: Error {
  case unsupportedHTTPMethod(String)
  case duplicatePathParameter([String])
  case missingRequiredPathParameter(String)
  case multipleBodyIteration
}

extension [Vapor.PathComponent] {
  init(_ path: String) {
    self = path.split(
      separator: "/",
      omittingEmptySubsequences: true
    ).map { parameter in
      if parameter.first == "{", parameter.last == "}" {
        return .parameter(String(parameter.dropFirst().dropLast()))
      } else {
        return .constant(String(parameter))
      }
    }
  }
}

extension HTTPTypes.HTTPRequest {
  init(_ vaporRequest: Vapor.Request) throws {
    let headerFields: HTTPTypes.HTTPFields = .init(vaporRequest.headers, splitCookie: true)
    let method = try HTTPTypes.HTTPRequest.Method(vaporRequest.method)
    let queries = vaporRequest.url.query.map { "?\($0)" } ?? ""
    self.init(
      method: method,
      scheme: vaporRequest.url.scheme,
      authority: vaporRequest.url.host,
      path: vaporRequest.url.path + queries,
      headerFields: headerFields
    )
  }
}

extension OpenAPIRuntime.HTTPBody {
  convenience init(_ vaporRequest: Vapor.Request) {
    let contentLength = vaporRequest.headers.first(name: "content-length").map(Int.init)
    self.init(
      vaporRequest.body.map(\.readableBytesView),
      length: contentLength?.map { .known(numericCast($0)) } ?? .unknown,
      iterationBehavior: .single
    )
  }
}

extension OpenAPIRuntime.ServerRequestMetadata {
  init(from vaporRequest: Vapor.Request, forPath path: String) throws {
    self.init(pathParameters: try .init(from: vaporRequest, forPath: path))
  }
}

extension [String: Substring] {
  init(from vaporRequest: Vapor.Request, forPath path: String) throws {
    let keysAndValues = try [PathComponent](path).compactMap { component throws -> String? in
      guard case .parameter(let parameter) = component else {
        return nil
      }
      return parameter
    }.map { parameter -> (String, Substring) in
      guard let value = vaporRequest.parameters.get(parameter) else {
        throw VaporTransportError.missingRequiredPathParameter(parameter)
      }
      return (parameter, Substring(value))
    }
    let pathParameterDictionary = try Dictionary(
      keysAndValues,
      uniquingKeysWith: { _, _ in
        throw VaporTransportError.duplicatePathParameter(keysAndValues.map(\.0))
      })
    self = pathParameterDictionary
  }
}

extension Vapor.Response {
  convenience init(response: HTTPTypes.HTTPResponse, body: OpenAPIRuntime.HTTPBody?) {
    self.init(
      status: .init(statusCode: response.status.code),
      headers: .init(response.headerFields),
      body: .init(body)
    )
  }
}

extension Vapor.Response.Body {
  init(_ body: OpenAPIRuntime.HTTPBody?) {
    guard let body else {
      self = .empty
      return
    }
    /// Used to guard the body from being iterated multiple times.
    /// https://github.com/vapor/vapor/issues/3002
    let iterated = ManagedAtomic(false)
    let stream: @Sendable (any Vapor.BodyStreamWriter) -> Void = { writer in
      guard
        iterated.compareExchange(
          expected: false,
          desired: true,
          ordering: .relaxed
        ).exchanged
      else {
        _ = writer.write(.error(VaporTransportError.multipleBodyIteration))
        return
      }
      _ = writer.eventLoop.makeFutureWithTask {
        do {
          for try await chunk in body {
            try await writer.write(.buffer(ByteBuffer(bytes: chunk))).get()
          }
          try await writer.write(.end).get()
        } catch {
          try await writer.write(.error(error)).get()
        }
      }
    }
    switch body.length {
    case .known(let count):
      self = .init(stream: stream, count: Int(clamping: count))
    case .unknown:
      self = .init(stream: stream)
    }
  }
}
