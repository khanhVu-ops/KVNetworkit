//
//  KVNetworkSession.swift
//  KVNetworkit
//

import Foundation

/// Default `URLSession`-backed implementation of ``KVNetworkSessionProtocol``.
public final class KVNetworkSession: KVNetworkSessionProtocol, @unchecked Sendable {

    private let session: URLSession

    /// Creates a session with the given timeouts.
    ///
    /// - Parameters:
    ///   - requestTimeout: Timeout for a single request (seconds). Defaults to 60.
    ///   - resourceTimeout: Timeout for the whole transfer, relevant for uploads/downloads. Defaults to 300.
    ///   - delegate: Optional `URLSessionDelegate` (e.g. for upload progress or pinning).
    ///   - configuration: Base configuration. Defaults to `.default`.
    ///     `URLCache` is disabled because caching is handled explicitly by ``KVAPIClient``.
    public init(
        requestTimeout: TimeInterval = 60,
        resourceTimeout: TimeInterval = 300,
        delegate: URLSessionDelegate? = nil,
        configuration: URLSessionConfiguration = .default
    ) {
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Wraps a pre-configured `URLSession`.
    public init(session: URLSession) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    public func bytes(for request: URLRequest) async throws -> (KVDataStream, URLResponse) {
        var storedContinuation: KVDataStream.Continuation?
        // The build closure runs synchronously, so the continuation is set on return.
        let stream = KVDataStream(bufferingPolicy: .unbounded) { storedContinuation = $0 }
        guard let continuation = storedContinuation else {
            throw KVAPIClientError.requestFailed(URLError(.unknown))
        }

        let task = session.dataTask(with: request)
        continuation.onTermination = { _ in task.cancel() }

        do {
            // Chunks arriving before the caller starts iterating are held by the stream's
            // unbounded buffer, so nothing is lost between the head and the first `for await`.
            let response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (awaiting: CheckedContinuation<URLResponse, any Error>) in
                    task.delegate = KVStreamTaskDelegate(
                        onResponse: { awaiting.resume(with: $0) },
                        onChunk: { continuation.yield($0) },
                        onFinish: { continuation.finish(throwing: $0) }
                    )
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
            return (stream, response)
        } catch {
            continuation.finish(throwing: error)
            throw error
        }
    }
}
