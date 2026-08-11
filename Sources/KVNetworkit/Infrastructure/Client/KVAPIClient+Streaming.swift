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

        if taskManager.status(for: id) == .inProgress {
            throw KVAPIClientError.taskInProgress
        }

        let (upstream, response) = try await establishStream(urlRequest)

        let streamInterceptors = interceptors.compactMap { $0 as? any KVStreamInterceptorProtocol }
        for interceptor in streamInterceptors {
            await interceptor.streamDidOpen(id: id, response: response)
        }

        return trackedStream(upstream, id: id, interceptors: streamInterceptors)
    }
}

// MARK: - Stream pipeline

private extension KVAPIClient {

    /// Runs interceptors, opens the connection and validates the response head.
    ///
    /// - Returns: The body chunk stream and the validated HTTP response.
    func establishStream(
        _ originalRequest: URLRequest,
        hasRefreshedToken: Bool = false
    ) async throws -> (KVDataStream, HTTPURLResponse) {
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
                    return try await establishStream(originalRequest, hasRefreshedToken: true)
                }

                let (finalData, finalResponse) = try await interceptResponse(
                    data: errorData,
                    response: response
                )

                // 6. Retry on retryable status codes.
                if retryPolicy.shouldRetry(statusCode: http.statusCode), attempt < retryPolicy.maxRetries {
                    attempt += 1
                    try await backoff(attempt: attempt)
                    continue
                }

                // Always throws for a non-2xx status, preferring the server's message.
                try validateResponse(finalResponse, data: finalData)
                throw KVAPIClientError.statusCode(http.statusCode)
            } catch {
                if error is CancellationError { throw error }

                let mappedError = mapError(error)

                // Retry on retryable transport errors.
                if retryPolicy.shouldRetry(error: mappedError), attempt < retryPolicy.maxRetries {
                    attempt += 1
                    try await backoff(attempt: attempt)
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

    /// Re-publishes the transport stream through a cancellable, identifier-tracked task
    /// so `cancelRequest(with:)` and `cancelAllRequests()` also stop streams, running
    /// each chunk past the stream interceptors on the way.
    func trackedStream(
        _ upstream: KVDataStream,
        id: String,
        interceptors streamInterceptors: [any KVStreamInterceptorProtocol]
    ) -> KVDataStream {
        var storedContinuation: KVDataStream.Continuation?
        let downstream = KVDataStream(bufferingPolicy: .unbounded) { storedContinuation = $0 }
        guard let continuation = storedContinuation else { return upstream }

        let pump = Task<Void, any Error> {
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
                failure = mapError(error)
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
            taskManager.complete(id: id)
        }

        taskManager.register(pump, for: id)
        continuation.onTermination = { _ in pump.cancel() }

        return downstream
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
