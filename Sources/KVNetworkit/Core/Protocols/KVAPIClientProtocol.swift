//
//  KVAPIClientProtocol.swift
//  KVNetworkit
//

import Foundation

/// An API client that sends requests to ``KVAPIEndpointProtocol`` endpoints
/// and decodes their responses.
///
/// All methods are asynchronous and throw ``KVAPIClientError`` on failure.
public protocol KVAPIClientProtocol: Sendable {
    /// The interceptors applied to every request/response, in order.
    var interceptors: [any KVNetworkInterceptorProtocol] { get }

    /// The underlying network session.
    var session: any KVNetworkSessionProtocol { get }

    /// Sends a request and decodes the response body into `T`.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint to request.
    ///   - decoder: The decoder used for the response body.
    ///   - id: A unique identifier for the request, usable with ``cancelRequest(with:)``.
    func request<T: Decodable>(
        _ endpoint: any KVAPIEndpointProtocol,
        decoder: JSONDecoder,
        id: String
    ) async throws -> T

    /// Sends a request where only success/failure matters (POST, DELETE, PATCH, ...).
    func request(
        _ endpoint: any KVAPIEndpointProtocol,
        id: String
    ) async throws

    /// Sends a request and returns the raw response data, optionally reporting upload progress.
    @discardableResult
    func request(
        _ endpoint: any KVAPIEndpointProtocol,
        progressDelegate: (any KVUploadProgressDelegateProtocol)?,
        id: String
    ) async throws -> Data?

    /// Sends a request and returns the response body as it arrives, without buffering it.
    ///
    /// Use this for long-lived responses: server-sent events, LLM token streams,
    /// NDJSON feeds. The call returns once the response head has been validated,
    /// so a non-2xx status throws here — before the first chunk is consumed.
    ///
    /// Prefer ``streamEvents(_:framing:id:)`` or ``stream(_:as:decoder:framing:id:)``
    /// unless you need the raw bytes.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint to request. Its ``KVCachePolicy`` is ignored —
    ///     streamed responses are never cached.
    ///   - accept: `Accept` header applied only when the endpoint declares none.
    ///   - id: A unique identifier for the request, usable with ``cancelRequest(with:)``.
    func stream(
        _ endpoint: any KVAPIEndpointProtocol,
        accept: String?,
        id: String
    ) async throws -> KVDataStream

    /// Cancels the in-flight request with the given identifier.
    func cancelRequest(with id: String)

    /// Cancels all in-flight requests started by this client.
    func cancelAllRequests()
}

// MARK: - Convenience overloads

public extension KVAPIClientProtocol {
    /// Sends a request and decodes the response with a default `JSONDecoder` and a random id.
    func request<T: Decodable>(
        _ endpoint: any KVAPIEndpointProtocol,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        try await request(endpoint, decoder: decoder, id: UUID().uuidString)
    }

    /// Sends a fire-and-check request with a random id.
    func request(_ endpoint: any KVAPIEndpointProtocol) async throws {
        try await request(endpoint, id: UUID().uuidString)
    }

    /// Sends a raw-data request with a random id.
    @discardableResult
    func request(
        _ endpoint: any KVAPIEndpointProtocol,
        progressDelegate: (any KVUploadProgressDelegateProtocol)?
    ) async throws -> Data? {
        try await request(endpoint, progressDelegate: progressDelegate, id: UUID().uuidString)
    }
}

// MARK: - Streaming

public extension KVAPIClientProtocol {

    /// Streams the raw response chunks with a random id and no added `Accept` header.
    func stream(_ endpoint: any KVAPIEndpointProtocol) async throws -> KVDataStream {
        try await stream(endpoint, accept: nil, id: UUID().uuidString)
    }

    /// Streams the response as complete text lines.
    ///
    /// Chunk boundaries and multi-byte characters are reassembled, so every element
    /// is a whole line. Useful for inspecting an unfamiliar stream format.
    func streamLines(
        _ endpoint: any KVAPIEndpointProtocol,
        id: String = UUID().uuidString
    ) async throws -> AsyncThrowingStream<String, any Error> {
        let upstream = try await stream(endpoint, accept: nil, id: id)

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let pump = Task {
                var accumulator = KVLineAccumulator()
                do {
                    for try await chunk in upstream {
                        for line in accumulator.lines(from: chunk) {
                            continuation.yield(line)
                        }
                    }
                    if let tail = accumulator.flush() { continuation.yield(tail) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    /// Streams the response as parsed ``KVServerSentEvent`` values.
    ///
    /// ```swift
    /// for try await event in try await client.streamEvents(ChatEndpoint.interact(text)) {
    ///     guard !event.isDoneSentinel else { break }
    ///     let delta = try event.decode(ChatDelta.self)
    ///     await appendToBubble(delta.content)
    /// }
    /// ```
    ///
    /// - Parameter framing: How the server delimits events. Defaults to spec SSE;
    ///   use ``KVStreamFraming/serverSentEventsPerLine`` for backends that skip the
    ///   blank separator line.
    func streamEvents(
        _ endpoint: any KVAPIEndpointProtocol,
        framing: KVStreamFraming = .serverSentEvents,
        id: String = UUID().uuidString
    ) async throws -> AsyncThrowingStream<KVServerSentEvent, any Error> {
        let upstream = try await stream(endpoint, accept: framing.acceptHeader, id: id)

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let pump = Task {
                var parser = KVSSEParser(framing: framing)
                do {
                    for try await chunk in upstream {
                        for event in parser.parse(chunk) {
                            continuation.yield(event)
                        }
                    }
                    for event in parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    /// Streams the response as decoded values, one per event payload.
    ///
    /// The `[DONE]` sentinel and empty payloads are skipped; the stream ends when
    /// the server closes the connection. A payload that fails to decode throws
    /// ``KVAPIClientError/decodingFailed(_:)`` and ends the stream — use
    /// ``streamEvents(_:framing:id:)`` when the server mixes in payload shapes you
    /// want to ignore.
    ///
    /// ```swift
    /// let deltas: AsyncThrowingStream<ChatDelta, any Error> = try await client.stream(
    ///     ChatEndpoint.interact(text),
    ///     as: ChatDelta.self
    /// )
    /// ```
    func stream<T: Decodable>(
        _ endpoint: any KVAPIEndpointProtocol,
        as type: T.Type,
        decoder: JSONDecoder = JSONDecoder(),
        framing: KVStreamFraming = .serverSentEvents,
        id: String = UUID().uuidString
    ) async throws -> AsyncThrowingStream<T, any Error> {
        let events = try await streamEvents(endpoint, framing: framing, id: id)
        // Decoded on demand, in the consumer's task: `T` never crosses a task boundary, so it
        // does not have to be `Sendable`. Dropping this stream releases `events`, which
        // cancels the request.
        return KVDecodingEventIterator<T>(events.makeAsyncIterator(), decoder: decoder).makeStream()
    }
}

/// The pull side of ``KVAPIClientProtocol/stream(_:as:decoder:framing:id:)``.
///
/// `@unchecked Sendable` because `AsyncThrowingStream(unfolding:)` requires a `@Sendable`
/// closure, but only ever calls it from its single consumer, one call at a time.
final class KVDecodingEventIterator<T: Decodable>: @unchecked Sendable {
    private var events: AsyncThrowingStream<KVServerSentEvent, any Error>.Iterator
    private let decoder: JSONDecoder

    init(_ events: AsyncThrowingStream<KVServerSentEvent, any Error>.Iterator, decoder: JSONDecoder) {
        self.events = events
        self.decoder = decoder
    }

    func makeStream() -> AsyncThrowingStream<T, any Error> {
        AsyncThrowingStream { try await self.next() }
    }

    /// The next decoded payload, skipping the `[DONE]` sentinel and empty payloads.
    func next() async throws -> T? {
        while let event = try await events.next() {
            guard !event.isDoneSentinel, !event.data.isEmpty else { continue }
            return try event.decode(T.self, decoder: decoder)
        }
        return nil
    }
}
