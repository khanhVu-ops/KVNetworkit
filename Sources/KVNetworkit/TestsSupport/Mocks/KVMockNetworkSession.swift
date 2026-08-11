//
//  KVMockNetworkSession.swift
//  KVNetworkit
//

import Foundation

/// A ``KVNetworkSessionProtocol`` mock that returns scripted results and
/// records every request it receives.
///
/// ```swift
/// let session = KVMockNetworkSession()
/// session.enqueue(.success((jsonData, KVMockNetworkSession.httpResponse(url: url, statusCode: 200))))
/// let client = KVAPIClient(session: session, interceptors: [])
/// ```
public final class KVMockNetworkSession: KVNetworkSessionProtocol, @unchecked Sendable {

    /// A scripted streaming response.
    private enum QueuedStream {
        /// Chunks delivered in order, optionally followed by a mid-stream failure.
        case body(chunks: [Data], response: URLResponse, terminatingError: Error?)
        /// The connection itself fails; no response head is produced.
        case failure(Error)
    }

    private let lock = NSLock()
    private var queuedResults: [Result<(Data, URLResponse), Error>] = []
    private var queuedStreams: [QueuedStream] = []
    private var _receivedRequests: [URLRequest] = []

    /// Optional dynamic handler; takes precedence over queued results when set.
    public var handler: (@Sendable (URLRequest) throws -> (Data, URLResponse))?

    public init() {}

    /// All requests received, in order.
    public var receivedRequests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _receivedRequests
    }

    /// Adds a scripted result. Results are consumed in FIFO order; the last
    /// result is repeated once the queue is exhausted.
    public func enqueue(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        defer { lock.unlock() }
        queuedResults.append(result)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (handler, result) = record(request)

        if let handler {
            return try handler(request)
        }
        guard let result else {
            throw URLError(.badServerResponse)
        }
        return try result.get()
    }

    /// Records the request and dequeues the next scripted result, synchronously under the lock.
    private func record(
        _ request: URLRequest
    ) -> ((@Sendable (URLRequest) throws -> (Data, URLResponse))?, Result<(Data, URLResponse), Error>?) {
        lock.lock()
        defer { lock.unlock() }
        _receivedRequests.append(request)
        let result = queuedResults.count > 1 ? queuedResults.removeFirst() : queuedResults.first
        return (handler, result)
    }

    /// Dequeues the next scripted stream, recording the request only when one exists —
    /// otherwise `data(for:)` records it while serving the fallback.
    ///
    /// The last scripted stream is repeated once the queue is exhausted, matching
    /// the behavior of ``enqueue(_:)``.
    private func nextStream(recording request: URLRequest) -> QueuedStream? {
        lock.lock()
        defer { lock.unlock() }
        guard let next = queuedStreams.count > 1 ? queuedStreams.removeFirst() : queuedStreams.first else {
            return nil
        }
        _receivedRequests.append(request)
        return next
    }

    // MARK: - Streaming

    /// Scripts a streaming response: `chunks` are yielded in order, then the stream
    /// finishes — or fails with `terminatingError` to simulate a dropped connection.
    ///
    /// ```swift
    /// session.enqueueStream(
    ///     chunks: KVMockNetworkSession.sseChunks(["{\"t\":\"a\"}", "[DONE]"]),
    ///     response: KVMockNetworkSession.httpResponse(url: url, statusCode: 200)
    /// )
    /// ```
    public func enqueueStream(
        chunks: [Data],
        response: URLResponse,
        terminatingError: Error? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        queuedStreams.append(.body(chunks: chunks, response: response, terminatingError: terminatingError))
    }

    /// Scripts a streaming request that fails before any response head arrives.
    public func enqueueStream(error: Error) {
        lock.lock()
        defer { lock.unlock() }
        queuedStreams.append(.failure(error))
    }

    public func bytes(for request: URLRequest) async throws -> (KVDataStream, URLResponse) {
        guard let queued = nextStream(recording: request) else {
            // No stream scripted: fall back to the queued non-streaming results so a
            // single-chunk body can be scripted with `enqueue(_:)`.
            let (data, response) = try await data(for: request)
            return (KVDataStream { continuation in
                if !data.isEmpty { continuation.yield(data) }
                continuation.finish()
            }, response)
        }

        switch queued {
        case .failure(let error):
            throw error

        case .body(let chunks, let response, let terminatingError):
            let stream = KVDataStream(bufferingPolicy: .unbounded) { continuation in
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish(throwing: terminatingError)
            }
            return (stream, response)
        }
    }

    /// Splits a UTF-8 string into chunks of at most `size` bytes, to exercise parsers
    /// against payloads that do not align with line or event boundaries.
    public static func chunks(of text: String, size: Int) -> [Data] {
        let bytes = Array(text.utf8)
        return stride(from: 0, to: bytes.count, by: max(1, size)).map { start in
            Data(bytes[start..<min(start + size, bytes.count)])
        }
    }

    /// Wraps each payload as a spec-framed `data:` event, one `Data` chunk per event.
    public static func sseChunks(_ payloads: [String]) -> [Data] {
        payloads.map { Data("data: \($0)\n\n".utf8) }
    }

    /// Builds an `HTTPURLResponse` for scripting results.
    public static func httpResponse(
        url: URL,
        statusCode: Int,
        headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}
