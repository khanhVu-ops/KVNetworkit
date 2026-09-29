//
//  KVNetworkSession.swift
//  KVNetworkit
//

import Foundation

/// Default `URLSession`-backed implementation of ``KVNetworkSessionProtocol``.
///
/// Streams run on a second `URLSession` built from the same configuration, but with a
/// resource timeout of `streamResourceTimeout` — a server-sent event stream legitimately
/// stays open for longer than any single request should. `requestTimeout` still applies to
/// streams as an *idle* timeout: the connection fails if no data arrives for that long.
///
/// Sessions created by this type are invalidated when it is deallocated, letting in-flight
/// tasks finish first; a `URLSession` passed to ``init(session:)`` is left alone.
public final class KVNetworkSession: KVNetworkSessionProtocol, @unchecked Sendable {

    // Internal for tests.
    let session: URLSession
    private let ownsSession: Bool

    /// Builds the streaming session on first use, so clients that never stream don't pay for it.
    private let makeStreamSession: (() -> URLSession)?
    private let lock = NSLock()
    private var _streamSession: URLSession?

    /// Creates a session with the given timeouts.
    ///
    /// - Parameters:
    ///   - requestTimeout: Timeout for a single request (seconds), and the idle timeout of
    ///     streams. Defaults to 60.
    ///   - resourceTimeout: Timeout for the whole transfer, relevant for uploads/downloads. Defaults to 300.
    ///   - streamResourceTimeout: Maximum lifetime of a stream (seconds). Defaults to 7 days,
    ///     `URLSession`'s own default — in practice, until the server or the caller ends it.
    ///   - delegate: Optional `URLSessionDelegate` (e.g. for upload progress or pinning).
    ///     Also used by the streaming session.
    ///   - configuration: Base configuration. Defaults to `.default`.
    ///     `URLCache` is disabled because caching is handled explicitly by ``KVAPIClient``.
    public init(
        requestTimeout: TimeInterval = 60,
        resourceTimeout: TimeInterval = 300,
        streamResourceTimeout: TimeInterval = 7 * 24 * 60 * 60,
        delegate: URLSessionDelegate? = nil,
        configuration: URLSessionConfiguration = .default
    ) {
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.ownsSession = true

        // Copied now: the caller may keep mutating the configuration it passed in.
        let streamConfiguration = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        streamConfiguration.timeoutIntervalForResource = streamResourceTimeout
        self.makeStreamSession = {
            URLSession(configuration: streamConfiguration, delegate: delegate, delegateQueue: nil)
        }
    }

    /// Wraps a pre-configured `URLSession`, used for streams too. Streams are then bound by
    /// that session's `timeoutIntervalForResource`.
    public init(session: URLSession) {
        self.session = session
        self.ownsSession = false
        self.makeStreamSession = nil
    }

    deinit {
        guard ownsSession else { return }
        session.finishTasksAndInvalidate()
        _streamSession?.finishTasksAndInvalidate()
    }

    /// The session streams run on.
    var streamSession: URLSession {
        guard let makeStreamSession else { return session }
        lock.lock()
        defer { lock.unlock() }
        if let existing = _streamSession { return existing }
        let created = makeStreamSession()
        _streamSession = created
        return created
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

        let task = streamSession.dataTask(with: request)
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
