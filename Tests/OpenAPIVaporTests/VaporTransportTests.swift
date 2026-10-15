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
import RoutingKit
import Synchronization
import Testing
import Vapor
import VaporTesting

@testable import OpenAPIVapor

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Which testing transport a test runs over. `Application.Method` itself is not `Sendable`, so it
/// cannot be passed to `@Test(arguments:)` directly.
enum TestTransport: Sendable, CaseIterable, CustomStringConvertible {
    case inMemory
    case liveServer

    var method: Application.Method {
        switch self {
        case .inMemory: .inMemory
        case .liveServer: .running
        }
    }

    var description: String {
        switch self {
        case .inMemory: "in memory"
        case .liveServer: "live server"
        }
    }
}

struct VaporTransportTests {

    /// A HEAD response declares the length of the body a GET would have returned, and sends no body.
    /// Over a real connection this also proves the length survives the wire with nothing following.
    @Test(arguments: TestTransport.allCases)
    func headRequestExplicitContentLength(over transport: TestTransport) async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app)
            let response = HTTPTypes.HTTPResponse(
                status: .ok,
                headerFields: [
                    .contentLength: "42"
                ]
            )
            try openAPITransport.register(
                { _, _, _ in (response, nil) },
                method: .head,
                path: "/test"
            )

            try await app.testing(transport.method) { client in
                let res = try await client.send(.head, to: "/test")
                #expect(res.status == .ok)
                #expect(res.headers[.contentLength] == "42")
                // In memory there is no body at all, over a connection an empty one; same thing here.
                let bodyString = try await res.body.string() ?? ""
                #expect(bodyString == "")
            }
        }
    }

    @Test
    func requestConversion() async throws {
        try await withApp { app in
            // POST /hello/{name}/world
            app.post("hello", ":name", "world") { vaporRequest -> Response in
                // Hijack the request handler to test the request-conversion functions.
                let expectedRequest = HTTPTypes.HTTPRequest(
                    method: .post,
                    scheme: nil,
                    authority: nil,
                    path: "/hello/Maria/world?greeting=Howdy",
                    headerFields: [
                        HTTPField.Name("X-Mumble")!: "mumble",
                        HTTPField.Name("content-length")!: "4",
                    ]
                )
                let expectedRequestMetadata = ServerRequestMetadata(
                    pathParameters: ["name": "Maria"]
                )
                let request = try HTTPTypes.HTTPRequest(vaporRequest)
                // Builds the body the way `register` does. This runs inside the route, so a throw would
                // surface as a 500 and hide the real assertion.
                let body = try #require(try VaporRequestBody(vaporRequest, maxBodySize: .default).httpBody)
                let collectedBody = try await [UInt8](collecting: body, upTo: .max)
                let metadata = try ServerRequestMetadata(from: vaporRequest, forPath: "/hello/{name}/world")
                #expect(request == expectedRequest)
                #expect(collectedBody == [UInt8]("👋".utf8))
                #expect(metadata == expectedRequestMetadata)

                // Use the response-conversion to create the Vapor response for returning.
                let response = HTTPTypes.HTTPResponse(
                    status: .created,
                    headerFields: [
                        HTTPField.Name("X-Mumble")!: "mumble"
                    ]
                )
                return try Vapor.Response(response: response, body: .init([UInt8]("👋".utf8)))
            }

            try await app.testing { client in
                let res = try await client.post(
                    "/hello/Maria/world?greeting=Howdy",
                    headers: [HTTPField.Name("X-Mumble")!: "mumble"]
                ) { request in
                    request.body = .init(string: "👋")
                }
                #expect(res.status.code == 201)
            }
        }
    }

    /// The streaming branch of `Response.Body`: a body of unknown length has to reach the client
    /// chunked, in order and whole.
    @Test(arguments: TestTransport.allCases)
    func streamingResponseBodyOfUnknownLength(over transport: TestTransport) async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app)
            let chunks: [HTTPBody.ByteChunk] = [ArraySlice("Hello, ".utf8), ArraySlice("world!".utf8)]
            try openAPITransport.register(
                { _, _, _ in
                    let stream = AsyncStream<HTTPBody.ByteChunk> { continuation in
                        for chunk in chunks {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    }
                    return (HTTPTypes.HTTPResponse(status: .ok), HTTPBody(stream, length: .unknown))
                },
                method: .get,
                path: "/stream"
            )

            try await app.testing(transport.method) { client in
                let res = try await client.get("/stream")
                #expect(res.status == .ok)
                // An unknown length means chunked framing, so no `Content-Length` is declared.
                #expect(res.headers[.contentLength] == nil)
                try #expect(await res.body.requireString() == "Hello, world!")
            }
        }
    }

    /// RFC 9112 §6.1 forbids `Content-Length` alongside `Transfer-Encoding`, so a length the handler
    /// declared must not be restored onto a chunked response.
    @Test(arguments: TestTransport.allCases)
    func unknownLengthBodyIgnoresDeclaredContentLength(over transport: TestTransport) async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app)
            try openAPITransport.register(
                { _, _, _ in
                    let stream = AsyncStream<HTTPBody.ByteChunk> { continuation in
                        continuation.yield(ArraySlice("hi".utf8))
                        continuation.finish()
                    }
                    return (
                        HTTPTypes.HTTPResponse(status: .ok, headerFields: [.contentLength: "999"]),
                        HTTPBody(stream, length: .unknown)
                    )
                },
                method: .get,
                path: "/stream"
            )

            try await app.testing(transport.method) { client in
                let res = try await client.get("/stream")
                #expect(res.status == .ok)
                #expect(res.headers[.contentLength] == nil)
                try #expect(await res.body.requireString() == "hi")
            }
        }
    }

    /// A chunked upload arrives without `Content-Length`, and nothing collects it up front, so the
    /// length is `.unknown`. The bytes still have to arrive in full.
    @Test
    func chunkedRequestBodyStreamsWithUnknownLength() async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app)
            let seen = Mutex<(length: HTTPBody.Length, bytes: [UInt8])?>(nil)
            try openAPITransport.register(
                { _, body, _ in
                    if let body {
                        let bytes = try await [UInt8](collecting: body, upTo: .max)
                        seen.withLock { $0 = (body.length, bytes) }
                    }
                    return (HTTPTypes.HTTPResponse(status: .ok), nil)
                },
                method: .post,
                path: "/upload"
            )

            try await app.testing(.running) { client in
                let res = try await client.post("/upload") { request in
                    // A stream without a count is framed chunked, so no `Content-Length` is sent.
                    request.body = .init(stream: { writer in
                        try await writer.write("hello".utf8)
                    })
                }
                #expect(res.status == .ok)
            }

            let captured = seen.withLock { $0 }
            #expect(captured?.length == .unknown)
            #expect(captured?.bytes == [UInt8]("hello".utf8))
        }
    }

    /// A chunked upload declares no length, so the up-front check cannot help and the ceiling has to
    /// be enforced as the bytes arrive. The declared-length tests never reach that counter.
    @Test
    func chunkedRequestBodyOverTheCeilingIsRejectedMidStream() async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app, maxBodySize: .specified("1kb"))
            try openAPITransport.register(
                { _, body, _ in
                    // Reading is what trips the ceiling, so the handler has to actually read.
                    if let body {
                        _ = try await [UInt8](collecting: body, upTo: .max)
                    }
                    return (HTTPTypes.HTTPResponse(status: .ok), nil)
                },
                method: .post,
                path: "/upload"
            )

            try await app.testing(.running) { client in
                let res = try await client.post("/upload") { request in
                    // No count, so this is framed chunked and carries no `Content-Length`.
                    request.body = .init(stream: { writer in
                        for _ in 0..<4 {
                            try await writer.write(String(repeating: "a", count: 512).utf8)
                        }
                    })
                }
                #expect(res.status == .contentTooLarge)
                #expect(res.headers[.connection] == "close")
            }
        }
    }

    /// Generated code does not let a body failure through as is: it wraps it in `ServerError`, which
    /// on its own reaches the client as a 500. The ceiling still has to answer 413.
    @Test
    func requestBodyOverTheCeilingIsA413ThroughServerError() async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app, maxBodySize: .specified("1kb"))
            try openAPITransport.register(
                { request, body, metadata in
                    do {
                        if let body {
                            _ = try await [UInt8](collecting: body, upTo: .max)
                        }
                        return (HTTPTypes.HTTPResponse(status: .ok), nil)
                    } catch {
                        // What a generated `UniversalServer` handler does with a failure.
                        throw OpenAPIRuntime.ServerError(
                            operationID: "upload",
                            request: request,
                            requestBody: body,
                            requestMetadata: metadata,
                            causeDescription: "Reading the request body failed",
                            underlyingError: error
                        )
                    }
                },
                method: .post,
                path: "/upload"
            )

            try await app.testing(.running) { client in
                let res = try await client.post("/upload") { request in
                    request.body = .init(stream: { writer in
                        for _ in 0..<4 {
                            try await writer.write(String(repeating: "a", count: 512).utf8)
                        }
                    })
                }
                #expect(res.status == .contentTooLarge)
                #expect(res.headers[.connection] == "close")
            }
        }
    }

    /// A body something upstream already collected — the in-memory client's, or one a middleware read —
    /// replays from the start on every `withReader`, so it must not be read one scope per chunk.
    @Test(arguments: TestTransport.allCases)
    func requestBodyReachesTheHandlerOnce(over transport: TestTransport) async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app)
            try openAPITransport.register(
                { _, body, _ in
                    let bytes = try await [UInt8](collecting: try #require(body), upTo: .max)
                    return (HTTPTypes.HTTPResponse(status: .ok), HTTPBody(bytes))
                },
                method: .post,
                path: "/echo"
            )

            try await app.testing(transport.method) { client in
                let res = try await client.post("/echo") { request in
                    request.body = .init(string: "hello")
                }
                #expect(res.status == .ok)
                try #expect(await res.body.requireString() == "hello")
            }
        }
    }

    /// Whether a request carries a body is read off the framing, since nothing is collected up front.
    /// Pins what a handler sees for a plain GET.
    @Test
    func requestWithoutABodyGivesTheHandlerNoBody() async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app)
            let sawBody = Mutex<Bool?>(nil)
            try openAPITransport.register(
                { _, body, _ in
                    sawBody.withLock { $0 = body != nil }
                    return (HTTPTypes.HTTPResponse(status: .ok), nil)
                },
                method: .get,
                path: "/ping"
            )

            try await app.testing(.running) { client in
                let res = try await client.get("/ping")
                #expect(res.status == .ok)
            }

            #expect(sawBody.withLock { $0 } == false)
        }
    }

    /// The ceiling is only reached by reading, so a handler that ignores a chunked body never trips
    /// it — and the server has to drain what was left so the connection serves the next request.
    ///
    /// A declared `Content-Length` is different: it is refused up front whether the handler reads or
    /// not, which is why this uses a chunked body.
    @Test
    func unreadChunkedRequestBodyLeavesTheConnectionUsable() async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app, maxBodySize: .specified("1kb"))
            try openAPITransport.register(
                { _, _, _ in (HTTPTypes.HTTPResponse(status: .ok), nil) },
                method: .post,
                path: "/ignore"
            )

            try await app.testing(.running) { client in
                // Over the ceiling and chunked, but nothing reads it, so nothing rejects it.
                let first = try await client.post("/ignore") { request in
                    request.body = .init(stream: { writer in
                        try await writer.write(String(repeating: "a", count: 2048).utf8)
                    })
                }
                #expect(first.status == .ok)

                let second = try await client.post("/ignore") { request in
                    request.body = .init(string: "again")
                }
                #expect(second.status == .ok)
            }
        }
    }

    /// A path template naming the same parameter twice is a registration mistake; the transport has to
    /// refuse rather than silently keep one of the values.
    @Test
    func duplicatePathParameterIsRejected() async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app)
            try openAPITransport.register(
                { _, _, _ in (HTTPTypes.HTTPResponse(status: .ok), nil) },
                method: .get,
                path: "/{id}/thing/{id}"
            )

            try await app.testing { client in
                let res = try await client.get("/1/thing/2")
                // `VaporTransportError` is not an `AbortError`, so this arrives as a bare 500.
                #expect(res.status == .internalServerError)
            }
        }
    }

    /// The handler returns the request body as the response body. Nothing buffers it, so reading has
    /// to still work while the response is written — after the route closure has already returned.
    @Test
    func requestBodyCanBeStreamedIntoTheResponse() async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app)
            try openAPITransport.register(
                { _, body, _ in (HTTPTypes.HTTPResponse(status: .ok), body) },
                method: .post,
                path: "/echo"
            )

            try await app.testing(.running) { client in
                let res = try await client.post("/echo") { request in
                    request.body = .init(string: "streamed straight through")
                }
                #expect(res.status == .ok)
                try #expect(await res.body.requireString() == "streamed straight through")
            }
        }
    }

    /// The ceiling defaults to the application's 16 KB. The Vapor 4 transport had no limit, so this
    /// is the behaviour change a migrating user will notice.
    ///
    /// The ceiling tests use a real connection on purpose: the in-memory client hands over an
    /// already-collected body, which the transport passes through unchecked.
    @Test
    func requestBodyOverTheDefaultCeilingIsRejected() async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app)
            try openAPITransport.register(
                { _, _, _ in (HTTPTypes.HTTPResponse(status: .ok), nil) },
                method: .post,
                path: "/upload"
            )

            try await app.testing(.running) { client in
                let res = try await client.post("/upload") { request in
                    request.body = .init(string: String(repeating: "a", count: 21 * 1024))
                }
                #expect(res.status == .contentTooLarge)
                #expect(res.headers[.connection] == "close")
            }
        }
    }

    /// The ceiling is the transport's to set, so an API whose operations take larger payloads does
    /// not have to raise the limit for the whole application.
    @Test
    func requestBodyCeilingCanBeRaised() async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app, maxBodySize: .specified("64kb"))
            try openAPITransport.register(
                { _, body, _ in
                    #expect(body?.length == .known(Int64(21 * 1024)))
                    return (HTTPTypes.HTTPResponse(status: .ok), nil)
                },
                method: .post,
                path: "/upload"
            )

            try await app.testing(.running) { client in
                let res = try await client.post("/upload") { request in
                    request.body = .init(string: String(repeating: "a", count: 21 * 1024))
                }
                #expect(res.status == .ok)
            }
        }
    }

    /// A segment mixing a parameter with literal text, which `ServerTransport` allows, has to match
    /// and yield its parameter. It used to become a constant containing braces, so the route was dead.
    ///
    /// Partly addresses https://github.com/vapor/swift-openapi-vapor/issues/23: registering
    /// `/{scope}/{name}/{version}` alongside still shadows this route, because RoutingKit's trie
    /// takes a wildcard branch before a partial one and only backtracks when it dead-ends. That
    /// precedence is RoutingKit's to change.
    @Test(arguments: TestTransport.allCases)
    func mixedPathSegmentRoutesAndYieldsItsParameter(over transport: TestTransport) async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app)
            try openAPITransport.register(
                { _, _, metadata in
                    (
                        HTTPTypes.HTTPResponse(status: .ok),
                        HTTPBody("archive:\(metadata.pathParameters["version"] ?? "")")
                    )
                },
                method: .get,
                path: "/{scope}/{name}/{version}.zip"
            )

            try await app.testing(transport.method) { client in
                let archive = try await client.get("/pointfreeco/swift-clocks/1.0.6.zip")
                #expect(archive.status == .ok)
                // The `.zip` suffix is literal, so it is not part of the captured version.
                try #expect(await archive.body.requireString() == "archive:1.0.6")
            }
        }
    }

    /// A segment with more than one parameter is a partial too, not a single parameter whose name
    /// happens to start with `{` and end with `}`.
    @Test(arguments: TestTransport.allCases)
    func segmentWithSeveralParametersYieldsEach(over transport: TestTransport) async throws {
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app)
            try openAPITransport.register(
                { _, _, metadata in
                    let name = metadata.pathParameters["name"] ?? ""
                    let ext = metadata.pathParameters["ext"] ?? ""
                    return (HTTPTypes.HTTPResponse(status: .ok), HTTPBody("\(name)|\(ext)"))
                },
                method: .get,
                path: "/files/{name}.{ext}"
            )

            try await app.testing(transport.method) { client in
                let res = try await client.get("/files/photo.jpg")
                #expect(res.status == .ok)
                try #expect(await res.body.requireString() == "photo|jpg")
            }
        }
    }

    /// The body can be collected through the `Request` after the transport made its `HTTPBody` —
    /// the request injection tutorial hands the handler that `Request`. A collected body replays
    /// from the start on every read, so the stream has to notice and yield it once.
    @Test
    func requestBodyCollectedAfterTheTransportReachesTheHandlerOnce() async throws {
        try await withApp { app in
            app.middleware.use(InjectedRequestMiddleware())
            let openAPITransport = VaporTransport(routesBuilder: app)
            try openAPITransport.register(
                { _, body, _ in
                    _ = try await #require(InjectedRequest.current).body.collect()
                    let bytes = try await [UInt8](collecting: try #require(body), upTo: 1024)
                    return (HTTPTypes.HTTPResponse(status: .ok), HTTPBody(bytes))
                },
                method: .post,
                path: "/echo"
            )

            try await app.testing(.running) { client in
                let res = try await client.post("/echo") { request in
                    request.body = .init(stream: { writer in
                        try await writer.write("hello".utf8)
                    })
                }
                #expect(res.status == .ok)
                try #expect(await res.body.requireString() == "hello")
            }
        }
    }

    /// An error thrown by the handler must reach the client as a failure rather than be swallowed
    /// into a success by the transport.
    @Test
    func handlerErrorSurfacesToClient() async throws {
        struct HandlerFailure: Error {}
        try await withApp { app in
            let openAPITransport = VaporTransport(routesBuilder: app)
            try openAPITransport.register(
                { _, _, _ in throw HandlerFailure() },
                method: .get,
                path: "/boom"
            )

            try await app.testing { client in
                let res = try await client.get("/boom")
                #expect(res.status == .internalServerError)
            }
        }
    }

    @Test
    func handlerRegistration() async throws {
        try await withApp { app in
            let transport = VaporTransport(routesBuilder: app)
            let response = HTTPTypes.HTTPResponse(status: .created)
            try transport.register(
                { _, _, _ in (response, nil) },
                method: .post,
                path: "/hello/{name}"
            )

            #expect(app.routes.all.first?.path == ["hello", ":name"])

            try await app.testing { client in
                let res = try await client.post(
                    "/hello/Maria?greeting=Howdy",
                    headers: [HTTPField.Name("X-Mumble")!: "mumble"]
                ) { request in
                    request.body = .init(string: "👋")
                }
                #expect(res.status == .created)
            }
        }
    }
}

/// The request injection tutorial's pattern: the `Request` reaches the handler through a task local.
enum InjectedRequest {
    @TaskLocal
    static var current: Request? = nil
}

struct InjectedRequestMiddleware: Middleware {
    func respond(to request: Request, chainingTo responder: any Responder) async throws -> Response {
        try await InjectedRequest.$current.withValue(request) {
            try await responder.respond(to: request)
        }
    }
}
