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

public import HTTPTypes
public import OpenAPIRuntime
import RoutingKit
public import Vapor

public final class VaporTransport {

    /// A routes builder with which to register request handlers.
    internal var routesBuilder: any Vapor.RoutesBuilder

    /// The ceiling on a request body handed to a handler.
    internal let maxBodySize: BodySizeLimit

    /// Creates a new transport.
    /// - Parameters:
    ///   - routesBuilder: A routes builder with which to register request handlers.
    ///   - maxBodySize: The largest request body to accept; beyond it the request is rejected with
    ///     `413 Content Too Large`. Defaults to the application's `Routes/defaultMaxBodySize` of
    ///     16 KB. Bodies stream, so the ceiling is checked as the handler reads — a declared
    ///     `Content-Length` over it is refused up front, and a chunked body the handler never reads
    ///     never trips it. A body middleware already collected is passed through as is.
    public init(routesBuilder: any Vapor.RoutesBuilder, maxBodySize: BodySizeLimit = .default) {
        self.routesBuilder = routesBuilder
        self.maxBodySize = maxBodySize
    }
}

extension VaporTransport: ServerTransport {
    public func register(
        _ handler:
            @concurrent @Sendable @escaping (
                HTTPTypes.HTTPRequest, OpenAPIRuntime.HTTPBody?, OpenAPIRuntime.ServerRequestMetadata
            ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?),
        method: HTTPRequest.Method,
        path: String
    ) throws {
        // The closure below is `@Sendable` and the transport is not, so read the value out here.
        let maxBodySize = self.maxBodySize
        self.routesBuilder.on(
            method,
            [PathComponent](path)
        ) { vaporRequest in
            let request = try HTTPTypes.HTTPRequest(vaporRequest)
            let body = try VaporRequestBody(vaporRequest, maxBodySize: maxBodySize).httpBody
            let requestMetadata = try OpenAPIRuntime.ServerRequestMetadata(
                from: vaporRequest, forPath: path)
            let res: (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?)
            do {
                res = try await handler(request, body, requestMetadata)
            } catch let error as OpenAPIRuntime.ServerError
                where (error.underlyingError as? Abort)?.status == .contentTooLarge
            {
                // Generated code wraps a failed body read in `ServerError`, which reaches the client as a 500.
                throw error.underlyingError
            }
            var response = try Vapor.Response(response: res.0, body: res.1)
            // `Response.init` derives Content-Length from the body; for HEAD the handler's value is the
            // one that matters, and restoring it is only safe when there is no body to contradict it.
            if res.1 == nil, let contentLength = res.0.headerFields[.contentLength] {
                response.headers[.contentLength] = contentLength
            }
            return response
        }
    }
}

enum VaporTransportError: Error {
    case duplicatePathParameter([String])
    case missingRequiredPathParameter(String)
}

extension [RoutingKit.PathComponent] {
    init(_ path: String) {
        self = path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map { segment in
            let inner = segment.dropFirst().dropLast()
            if segment.first == "{", segment.last == "}", !inner.contains("{"), !inner.contains("}") {
                return .parameter(String(inner))
            } else if segment.contains("{") {
                // A mixed segment like `/file/{name}.zip` or `{name}.{ext}`, which `ServerTransport` allows. RoutingKit
                // spells these `:` plus the template. A plain `{name}` route alongside still shadows it.
                return .init(stringLiteral: ":\(segment)")
            } else {
                return .constant(String(segment))
            }
        }
    }
}

extension HTTPTypes.HTTPRequest {
    init(_ vaporRequest: Vapor.Request) throws {
        let queries = vaporRequest.url.query.map { "?\($0)" } ?? ""
        self.init(
            method: vaporRequest.method,
            scheme: vaporRequest.url.scheme,
            authority: vaporRequest.url.host,
            path: vaporRequest.url.path + queries,
            headerFields: vaporRequest.headers
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
        let keysAndValues = try [PathComponent](path).flatMap { component -> [String] in
            switch component {
            case .parameter(let parameter):
                return [parameter]
            // A mixed segment carries its parameters inside the template, each stored under its own name.
            case .partialParameter(_, _, let parameters):
                return parameters.map(String.init)
            case .constant, .anything, .catchall:
                return []
            }
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
    init(response: HTTPTypes.HTTPResponse, body: OpenAPIRuntime.HTTPBody?) throws {
        self.init(
            status: response.status,
            headers: response.headerFields,
            body: try .init(body)
        )
    }
}

extension Vapor.Response.Body {
    init(_ body: OpenAPIRuntime.HTTPBody?) throws {
        guard let body else {
            self = .empty
            return
        }
        let stream: @Sendable (borrowing any HTTPBodyWriter & ~Escapable) async throws -> Void = { writer in
            for try await chunk in body {
                try await writer.write(chunk)
            }
        }
        switch body.length {
        case .known(let count):
            self = try .init(stream: stream, count: Int(clamping: count))
        case .unknown:
            self = .init(stream: stream)
        }
    }
}
