//
//  KVStreamTaskDelegate.swift
//  KVNetworkit
//

import Foundation

/// Bridges the delegate callbacks of a single streaming `URLSessionDataTask` into
/// closures, so ``KVNetworkSession`` can expose them as an `AsyncThrowingStream`.
///
/// Using the data-task delegate rather than `URLSession.bytes(for:)` hands us the
/// real network chunks as they arrive, instead of forcing a per-byte async
/// iteration for every byte of the response.
///
/// `URLSession` keeps a strong reference to a task-specific delegate until the
/// task completes, so the instance does not need to be retained by the caller.
final class KVStreamTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let onResponse: @Sendable (Result<URLResponse, any Error>) -> Void
    private let onChunk: @Sendable (Data) -> Void
    private let onFinish: @Sendable ((any Error)?) -> Void

    private let lock = NSLock()
    private var hasDeliveredResponse = false

    init(
        onResponse: @escaping @Sendable (Result<URLResponse, any Error>) -> Void,
        onChunk: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable ((any Error)?) -> Void
    ) {
        self.onResponse = onResponse
        self.onChunk = onChunk
        self.onFinish = onFinish
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        deliverResponse(.success(response))
        // Allow the body through even for error statuses: the payload usually carries
        // the server's error message, which the client surfaces to the caller.
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onChunk(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // A failure before any response (DNS, TLS, no connectivity) never reaches
        // `didReceive response:`, so the awaiting caller is resumed here instead.
        deliverResponse(.failure(error ?? URLError(.badServerResponse)))
        onFinish(error)
    }

    /// Delivers the response exactly once; later calls are ignored.
    private func deliverResponse(_ result: Result<URLResponse, any Error>) {
        lock.lock()
        let isFirst = !hasDeliveredResponse
        hasDeliveredResponse = true
        lock.unlock()

        guard isFirst else { return }
        onResponse(result)
    }
}
