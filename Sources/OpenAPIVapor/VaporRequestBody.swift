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

import HTTPTypes
import OpenAPIRuntime
import Vapor

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

struct VaporRequestBody: Sendable {
    /// The body as a lazy sequence of chunks: one `withReader` scope per chunk, so nothing
    /// non-escapable outlives a read. The stream lives in the request, so the position carries
    /// from one call to the next.
    struct RequestBodyChunks: AsyncSequence, Sendable {
        typealias Element = HTTPBody.ByteChunk

        let request: Vapor.Request
        let maxBodySize: Int

        func makeAsyncIterator() -> Iterator {
            Iterator(request: request, maxBodySize: maxBodySize)
        }

        struct Iterator: AsyncIteratorProtocol {
            let request: Vapor.Request
            let maxBodySize: Int
            private var bytesRead = 0
            private var finished = false

            init(request: Vapor.Request, maxBodySize: Int) {
                self.request = request
                self.maxBodySize = maxBodySize
            }

            mutating func next() async throws -> Element? {
                // Bound out of `self` before the closures: `self` is already `inout` here.
                let request = self.request
                // A read can come back empty without ending the body, and returning `nil` would say the
                // body is over — so keep reading until there are bytes or the stream ends.
                while !finished {
                    // Something can collect the body after this sequence was made: a middleware after
                    // `next.respond`, or a handler through the injected `Request`. A collected body
                    // replays from the start on every `withReader`, so hand it over once instead.
                    if let collected = request.body.data {
                        finished = true
                        // Vapor refuses to collect a stream that was partly read, so this is defensive.
                        guard bytesRead == 0 else {
                            throw Abort(.internalServerError, reason: "The request body was collected while it was being streamed.")
                        }
                        return collected.isEmpty ? nil : ArraySlice(collected)
                    }
                    let (chunk, isEnd) = try await request.body.withReader { reader in
                        try await reader.read { span, isEnd -> (Element?, Bool) in
                            // Take the bytes before looking at the flag: a terminal read may carry a final batch.
                            let chunk: Element? =
                                span.isEmpty
                                ? nil
                                : span.withUnsafeBufferPointer { unsafe ArraySlice($0) }
                            return (chunk, isEnd)
                        }
                    }
                    if isEnd {
                        finished = true
                    }
                    if let chunk {
                        bytesRead += chunk.count
                        guard bytesRead <= maxBodySize else {
                            throw Abort(.contentTooLarge, headers: [.connection: "close"])
                        }
                        return chunk
                    }
                }
                return nil
            }
        }
    }

    private enum Source: Sendable {
        /// Something upstream already collected the body. `withReader` replays a collected body from
        /// the start on every call, so it cannot be read one scope per chunk.
        case collected(Data)
        case stream(RequestBodyChunks, HTTPBody.Length)
    }

    private let source: Source?

    /// - Throws: `Abort` with `.contentTooLarge` when the declared `Content-Length` already exceeds
    ///   `maxBodySize`, refusing an oversized upload before any of it is read. It carries
    ///   `Connection: close`: the rest of the body is still on the wire and the server only drains so
    ///   much of it, so the client is told up front rather than handed keep-alive framing and cut off.
    init(_ request: Vapor.Request, maxBodySize: BodySizeLimit) throws {
        let declared = request.headers[.contentLength].flatMap { Int($0) }

        // Already in memory, so it was accepted under whatever limit collected it — as with Vapor's own
        // `collect(max:)`, a second ceiling does not re-reject it.
        if let collected = request.body.data {
            self.source = collected.isEmpty && declared == nil ? nil : .collected(collected)
            return
        }

        // `BodySizeLimit.bytes(default:)` is internal to Vapor, so resolve the ceiling here.
        let limit: Int =
            switch maxBodySize {
            case .default: request.maxBodySize.value
            case .unlimited: .max
            case .specified(let count): count.value
            }

        if let declared, declared > limit {
            throw Abort(.contentTooLarge, headers: [.connection: "close"])
        }

        // Nothing is collected up front, so the framing is the only signal that a body exists.
        guard declared != nil || request.headers[.transferEncoding] != nil else {
            self.source = nil
            return
        }
        self.source = .stream(
            RequestBodyChunks(request: request, maxBodySize: limit),
            declared.map { .known(Int64($0)) } ?? .unknown
        )
    }

    /// The body as an `HTTPBody`, or `nil` when the request carries none.
    ///
    /// A streamed body is `.single` because the bytes come off a socket and cannot be read twice.
    var httpBody: OpenAPIRuntime.HTTPBody? {
        switch source {
        case nil:
            return nil
        case .collected(let data):
            return HTTPBody([UInt8](data))
        case .stream(let chunks, let length):
            return HTTPBody(chunks, length: length, iterationBehavior: .single)
        }
    }
}
