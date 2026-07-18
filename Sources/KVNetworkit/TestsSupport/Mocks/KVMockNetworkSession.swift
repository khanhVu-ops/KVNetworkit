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

    private let lock = NSLock()
    private var queuedResults: [Result<(Data, URLResponse), Error>] = []
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

    /// Builds an `HTTPURLResponse` for scripting results.
    public static func httpResponse(
        url: URL,
        statusCode: Int,
        headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}
