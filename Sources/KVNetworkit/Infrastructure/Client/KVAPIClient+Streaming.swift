//
//  KVAPIClient+Streaming.swift
//  KVNetworkit
//

import Foundation

// MARK: - Streaming

public extension KVAPIClient {

    /// Opens a streaming request and returns its body chunks.
    ///
    /// The pipeline mirrors ``KVAPIClient/request(_:decoder:id:)`` for everything that
    /// applies before the first byte — request interceptors, retry with backoff,
    /// one-shot token refresh, status validation — then hands the still-open body to
    /// the caller. Two deliberate differences:
    ///
    /// - The cache is bypassed: a partial stream is not a cacheable response.
    /// - Retry only covers connection setup and the response head. Once chunks start
    ///   flowing, a mid-stream failure is surfaced instead of silently restarting,
    ///   because the caller has already consumed part of the output.
    func stream(
        _ endpoint: any KVAPIEndpointProtocol,
        accept: String? = nil,
        id: String = UUID().uuidString
    ) async throws -> KVDataStream {
        guard var urlRequest = endpoint.urlRequest else {
            throw KVAPIClientError.invalidURL
        }

        if let accept, urlRequest.value(forHTTPHeaderField: "Accept") == nil {
            urlRequest.setValue(accept, forHTTPHeaderField: "Accept")
        }

        let request = urlRequest
        let retryPolicy = endpoint.retryPolicy ?? retryPolicy
        let registration = KVTaskRegistration(id: id)
        let head = KVStreamHead()

        var storedContinuation: KVDataStream.Continuation?
        let downstream = KVDataStream(bufferingPolicy: .unbounded) { storedContinuation = $0 }
        guard let continuation = storedContinuation else {
            throw KVAPIClientError.requestFailed(URLError(.unknown))
        }

        // One task covers the whole stream — connection setup and body — and claims the id
        // up front, so `cancelRequest(with:)` works while connecting too, and a second
        // stream under the same id is rejected before it opens a connection.
        var createdTask: Task<Void, any Error>?
        let isRegistered = taskManager.register(registration) {
            let task = Task<Void, any Error> {
                await self.runStream(
                    request,
                    retryPolicy: retryPolicy,
                    registration: registration,
                    head: head,
                    continuation: continuation
                )
            }
            createdTask = task
            return task
        }
        guard isRegistered, let pump = createdTask else {
            continuation.finish()
            throw KVAPIClientError.taskInProgress
        }
        continuation.onTermination = { _ in pump.cancel() }

        // Canceling the caller while the connection is being set up cancels the stream.
        try await withTaskCancellationHandler {
            try await head.wait()
        } onCancel: {
            pump.cancel()
        }
        return downstream
    }
}

// MARK: - Stream pipeline

private extension KVAPIClient {

    /// Runs interceptors, opens the connection and validates the response head.
    ///
    /// - Returns: The body chunk stream and the validated HTTP response.
    func establishStream(
        _ originalRequest: URLRequest,
        retryPolicy: KVRetryPolicy,
        hasRefreshedToken: Bool = false
    ) async throws -> (KVDataStream, HTTPURLResponse) {
        let maxRetries = retryPolicy.shouldRetry(method: originalRequest.httpMethod) ? retryPolicy.maxRetries : 0
        var attempt = 0

        while true {
            do {
                // 1. Request interceptors (re-run per attempt so auth headers stay fresh).
                let interceptedRequest = try await interceptRequest(originalRequest)

                try Task.checkCancellation()

                // 2. Transport — returns as soon as the head is available.
                let (body, response) = try await session.bytes(for: interceptedRequest)

                guard let http = response as? HTTPURLResponse else {
                    throw KVAPIClientError.invalidResponse(await Self.drain(body))
                }

                // 3. Success: let interceptors see the head, then hand over the open body.
                if (200...299).contains(http.statusCode) {
                    let finalResponse = try await interceptStreamHead(response)
                    return (body, (finalResponse as? HTTPURLResponse) ?? http)
                }

                // 4. Failure: the error payload is short and lives in the body, so read it.
                //    Without this the server's message would be lost, leaving only a status code.
                let errorData = await Self.drain(body)

                // 5. Token refresh — at most one refresh-and-retry per logical request.
                if !hasRefreshedToken,
                   try await shouldRetryAfterTokenRefresh(response: response, data: errorData) {
                    return try await establishStream(
                        originalRequest,
                        retryPolicy: retryPolicy,
                        hasRefreshedToken: true
                    )
                }

                let (finalData, finalResponse) = try await interceptResponse(
                    data: errorData,
                    response: response
                )

                // 6. Retry on retryable status codes.
                if retryPolicy.shouldRetry(statusCode: http.statusCode), attempt < maxRetries {
                    attempt += 1
                    try await backoff(attempt: attempt, policy: retryPolicy, response: http)
                    continue
                }

                // Always throws for a non-2xx status, preferring the server's message.
                try validateResponse(finalResponse, data: finalData)
                throw KVAPIClientError.statusCode(http.statusCode)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }

                let mappedError = mapError(error)

                // Retry on retryable transport errors.
                if retryPolicy.shouldRetry(error: mappedError), attempt < maxRetries {
                    attempt += 1
                    try await backoff(attempt: attempt, policy: retryPolicy, response: nil)
                    continue
                }

                throw mappedError
            }
        }
    }

    /// Runs response interceptors on the head alone; the body has not arrived yet,
    /// so they are called with `nil` data.
    func interceptStreamHead(_ response: URLResponse) async throws -> URLResponse {
        var modified = response
        for interceptor in interceptors {
            let (newResponse, _) = try await interceptor.intercept(response: modified, data: nil)
            modified = newResponse ?? modified
        }
        return modified
    }

    /// The body of a stream's tracked task: opens the connection, reports the outcome to the
    /// waiting `stream(_:accept:id:)` call, then re-publishes the transport stream into
    /// `continuation`, running each chunk past the stream interceptors on the way.
    ///
    /// Tracking this task is what lets `cancelRequest(with:)` and `cancelAllRequests()`
    /// stop streams.
    func runStream(
        _ request: URLRequest,
        retryPolicy: KVRetryPolicy,
        registration: KVTaskRegistration,
        head: KVStreamHead,
        continuation: KVDataStream.Continuation
    ) async {
        let id = registration.id
        defer { taskManager.complete(registration) }

        let upstream: KVDataStream
        let streamInterceptors = interceptors.compactMap { $0 as? any KVStreamInterceptorProtocol }
        do {
            let (body, response) = try await establishStream(request, retryPolicy: retryPolicy)
            for interceptor in streamInterceptors {
                await interceptor.streamDidOpen(id: id, response: response)
            }
            upstream = body
        } catch {
            // Nothing opened, so stream interceptors are not told about it.
            let failure = error is CancellationError ? KVAPIClientError.taskCanceled : error
            head.resolve(.failure(failure))
            continuation.finish(throwing: failure)
            return
        }
        head.resolve(.success(()))

        let startedAt = Date()
        var chunkCount = 0
        var byteCount = 0
        var failure: (any Error)?

        do {
            for try await chunk in upstream {
                try Task.checkCancellation()

                var payload = chunk
                for interceptor in streamInterceptors {
                    if let replacement = try await interceptor.stream(id: id, didReceive: payload) {
                        payload = replacement
                    }
                }

                chunkCount += 1
                byteCount += payload.count
                continuation.yield(payload)
            }
            // A cancelled `AsyncThrowingStream` may simply end instead of throwing,
            // so an ended-because-cancelled stream is reported as a cancellation
            // rather than a clean completion.
            if Task.isCancelled {
                failure = KVAPIClientError.taskCanceled
            }
        } catch is CancellationError {
            failure = KVAPIClientError.taskCanceled
        } catch {
            failure = Task.isCancelled ? KVAPIClientError.taskCanceled : mapError(error)
        }

        // Interceptors are told before the consumer's loop ends, so that by the time
        // `for try await` returns or throws, logging and metrics have already run —
        // the same ordering a non-streamed request gets from its response interceptors.
        let statistics = KVStreamStatistics(
            chunkCount: chunkCount,
            byteCount: byteCount,
            duration: Date().timeIntervalSince(startedAt)
        )
        for interceptor in streamInterceptors {
            await interceptor.streamDidClose(id: id, statistics: statistics, error: failure)
        }

        continuation.finish(throwing: failure)
    }

    /// Reads a stream to completion, for error payloads only.
    ///
    /// Capped so a misbehaving server streaming megabytes under an error status cannot
    /// grow the buffer without bound. Read failures collapse to whatever arrived — the
    /// status code is the error being reported, not this read.
    static func drain(_ stream: KVDataStream, limit: Int = 512 * 1024) async -> Data {
        var data = Data()
        do {
            for try await chunk in stream {
                data.append(chunk)
                if data.count >= limit { break }
            }
        } catch {
            // Ignored: a partial payload is still better than none.
        }
        return data
    }
}

// MARK: - Stream head

/// One-shot hand-off of a stream's opening outcome from its task to the waiting caller.
///
/// Whichever of `resolve` and `wait` runs first, the waiter is resumed exactly once.
final class KVStreamHead: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var waiter: CheckedContinuation<Void, any Error>?

    func resolve(_ outcome: Result<Void, any Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let pending = waiter
        waiter = nil
        lock.unlock()

        pending?.resume(with: outcome)
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}
