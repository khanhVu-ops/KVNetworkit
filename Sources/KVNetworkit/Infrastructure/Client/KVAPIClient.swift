//
//  KVAPIClient.swift
//  KVNetworkit
//

import Foundation

/// The default KVNetworkit API client.
///
/// Responsibilities, in request order:
/// 1. Build the `URLRequest` from the endpoint.
/// 2. Serve from cache when the endpoint's ``KVCachePolicy`` allows it.
/// 3. Run request interceptors (auth headers, logging, connectivity check, ...).
/// 4. Execute the request, retrying per ``KVRetryPolicy`` with exponential backoff
///    (idempotent methods only, unless the policy says otherwise).
/// 5. Handle token refresh via ``KVTokenRefreshingInterceptorProtocol`` (at most once per request).
/// 6. Run response interceptors, validate the status code, store to cache.
///
/// ```swift
/// let client = KVAPIClient(
///     interceptors: [
///         KVAuthInterceptor(tokenProvider: { tokenStore.accessToken }),
///         KVLoggingInterceptor()
///     ],
///     retryPolicy: .default,
///     cache: KVHybridCache()
/// )
///
/// let user: User = try await client.request(UserEndpoint.profile)
/// ```
public final class KVAPIClient: KVAPIClientProtocol, @unchecked Sendable {

    // MARK: - Properties

    public let session: any KVNetworkSessionProtocol
    public let interceptors: [any KVNetworkInterceptorProtocol]

    /// The response cache, if configured. Expose it to clear on logout:
    /// `await client.cache?.removeAll()`.
    public let cache: (any KVNetworkCacheProtocol)?

    /// The retry policy applied to every request whose endpoint does not declare its own
    /// ``KVAPIEndpointProtocol/retryPolicy``.
    public let retryPolicy: KVRetryPolicy

    /// Maps error responses to the error thrown to the caller; see ``KVHTTPErrorResponse``.
    public let errorResponseMapper: KVErrorResponseMapper?

    /// Internal so the streaming pipeline in `KVAPIClient+Streaming.swift` can track
    /// long-lived stream tasks under the same identifiers as regular requests.
    let taskManager: any KVTaskManagerProtocol

    private let uploadSessionFactory: @Sendable (any KVUploadProgressDelegateProtocol) -> any KVNetworkSessionProtocol

    // MARK: - Initialization

    /// - Parameters:
    ///   - session: The transport. Defaults to a `URLSession`-backed ``KVNetworkSession``.
    ///   - interceptors: Applied to every request/response in order. Defaults to a ``KVLoggingInterceptor``.
    ///   - retryPolicy: Backoff/retry behavior. Defaults to ``KVRetryPolicy/never``.
    ///   - cache: Optional response cache. Endpoints opt in via ``KVAPIEndpointProtocol/cachePolicy``.
    ///   - errorResponseMapper: Builds the error thrown for a non-2xx response, from its status,
    ///     headers and raw body. Return `nil` for the default ``KVAPIClientError``. Defaults to `nil`.
    ///   - taskManager: Tracks in-flight tasks for cancellation. Defaults to a fresh ``KVTaskManager``.
    ///   - uploadSessionFactory: Builds the session used for progress-tracked uploads. The
    ///     session is released when the upload finishes; a ``KVNetworkSession`` invalidates its
    ///     `URLSession` at that point, so a session per upload does not leak.
    public init(
        session: any KVNetworkSessionProtocol = KVNetworkSession(),
        interceptors: [any KVNetworkInterceptorProtocol] = [KVLoggingInterceptor()],
        retryPolicy: KVRetryPolicy = .never,
        cache: (any KVNetworkCacheProtocol)? = nil,
        errorResponseMapper: KVErrorResponseMapper? = nil,
        taskManager: any KVTaskManagerProtocol = KVTaskManager(),
        uploadSessionFactory: @escaping @Sendable (any KVUploadProgressDelegateProtocol) -> any KVNetworkSessionProtocol = { delegate in
            KVNetworkSession(requestTimeout: 60, resourceTimeout: 600, delegate: delegate)
        }
    ) {
        self.session = session
        self.interceptors = interceptors
        self.retryPolicy = retryPolicy
        self.cache = cache
        self.errorResponseMapper = errorResponseMapper
        self.taskManager = taskManager
        self.uploadSessionFactory = uploadSessionFactory
    }

    // MARK: - KVAPIClientProtocol

    public func request<T: Decodable>(
        _ endpoint: any KVAPIEndpointProtocol,
        decoder: JSONDecoder = JSONDecoder(),
        id: String
    ) async throws -> T {
        guard let urlRequest = endpoint.urlRequest else {
            throw KVAPIClientError.invalidURL
        }

        let cachePolicy = endpoint.cachePolicy
        let retryPolicy = endpoint.retryPolicy ?? retryPolicy

        // Decoding happens here, in the caller's task: only `Data` crosses the task boundary,
        // so `T` does not have to be `Sendable`.
        let data = try await executeTracked(id: id) {
            try await self.performRequest(urlRequest, cachePolicy: cachePolicy, retryPolicy: retryPolicy)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw KVAPIClientError.decodingFailed(error)
        }
    }

    public func request(
        _ endpoint: any KVAPIEndpointProtocol,
        id: String
    ) async throws {
        guard let urlRequest = endpoint.urlRequest else {
            throw KVAPIClientError.invalidURL
        }

        let cachePolicy = endpoint.cachePolicy
        let retryPolicy = endpoint.retryPolicy ?? retryPolicy

        _ = try await executeTracked(id: id) {
            try await self.performRequest(urlRequest, cachePolicy: cachePolicy, retryPolicy: retryPolicy)
        }
    }

    @discardableResult
    public func request(
        _ endpoint: any KVAPIEndpointProtocol,
        progressDelegate: (any KVUploadProgressDelegateProtocol)? = nil,
        id: String
    ) async throws -> Data? {
        guard let urlRequest = endpoint.urlRequest else {
            throw KVAPIClientError.invalidURL
        }

        let cachePolicy = endpoint.cachePolicy
        let retryPolicy = endpoint.retryPolicy ?? retryPolicy

        return try await executeTracked(id: id) {
            try await self.performRequest(
                urlRequest,
                cachePolicy: cachePolicy,
                retryPolicy: retryPolicy,
                progressDelegate: progressDelegate
            )
        }
    }

    public func cancelRequest(with id: String) {
        taskManager.cancel(id: id)
    }

    public func cancelAllRequests() {
        taskManager.cancelAll()
    }
}

// MARK: - Task tracking

private extension KVAPIClient {
    /// Wraps an operation in a cancellable, identifier-tracked task.
    ///
    /// The task is canceled by ``cancelRequest(with:)`` *and* when the caller's own task is
    /// canceled (e.g. a SwiftUI `.task` whose view disappears); both throw
    /// ``KVAPIClientError/taskCanceled``.
    func executeTracked<T: Sendable>(
        id: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let registration = KVTaskRegistration(id: id)
        var createdTask: Task<T, any Error>?
        let isRegistered = taskManager.register(registration) {
            let task = Task { try await operation() }
            createdTask = task
            return task
        }
        guard isRegistered, let task = createdTask else {
            throw KVAPIClientError.taskInProgress
        }
        defer { taskManager.complete(registration) }

        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            // A canceled `URLSession` task surfaces as `URLError(.cancelled)`, not `CancellationError`.
            if error is CancellationError || task.isCancelled {
                throw KVAPIClientError.taskCanceled
            }
            throw error
        }
    }
}

// MARK: - Request pipeline

/// Internal rather than private: the streaming pipeline lives in
/// `KVAPIClient+Streaming.swift` and reuses the interception, retry and
/// validation steps below.
extension KVAPIClient {

    @discardableResult
    func performRequest(
        _ originalRequest: URLRequest,
        cachePolicy: KVCachePolicy,
        retryPolicy: KVRetryPolicy,
        progressDelegate: (any KVUploadProgressDelegateProtocol)? = nil,
        hasRefreshedToken: Bool = false
    ) async throws -> Data {
        // Key is derived from the pre-interception request so it is stable across token rotation.
        let cacheKey = KVCacheKey.make(for: originalRequest)

        // 1. Cache-first: serve a fresh entry without touching the network.
        if let cache, case let .cacheFirst(ttl) = cachePolicy,
           let entry = await cache.entry(for: cacheKey),
           entry.isFresh(ttl: ttl) {
            return entry.data
        }

        // Released when this call returns, which lets a per-upload session invalidate itself.
        let activeSession = progressDelegate.map(uploadSessionFactory) ?? session
        let maxRetries = retryPolicy.shouldRetry(method: originalRequest.httpMethod) ? retryPolicy.maxRetries : 0
        var attempt = 0

        while true {
            do {
                // 2. Request interceptors (re-run each attempt so auth headers stay fresh).
                let interceptedRequest = try await interceptRequest(originalRequest)

                try Task.checkCancellation()

                // 3. Transport.
                let (data, response) = try await activeSession.data(for: interceptedRequest)

                // 4. Token refresh — at most one refresh-and-retry per logical request.
                if !hasRefreshedToken,
                   try await shouldRetryAfterTokenRefresh(response: response, data: data) {
                    return try await performRequest(
                        originalRequest,
                        cachePolicy: cachePolicy,
                        retryPolicy: retryPolicy,
                        progressDelegate: progressDelegate,
                        hasRefreshedToken: true
                    )
                }

                // 5. Response interceptors.
                let (finalData, finalResponse) = try await interceptResponse(data: data, response: response)

                // 6. Retry on retryable status codes.
                if let http = finalResponse as? HTTPURLResponse,
                   retryPolicy.shouldRetry(statusCode: http.statusCode),
                   attempt < maxRetries {
                    attempt += 1
                    try await backoff(attempt: attempt, policy: retryPolicy, response: http)
                    continue
                }

                // 7. Validate and cache.
                try validateResponse(finalResponse, data: finalData)
                await storeInCache(finalData, response: finalResponse, policy: cachePolicy, key: cacheKey)
                return finalData
            } catch {
                // Canceling the task also cancels the `URLSession` task, which then fails
                // with `URLError(.cancelled)`; report that as the cancellation it is.
                if error is CancellationError || Task.isCancelled { throw CancellationError() }

                let mappedError = mapError(error)

                // Retry on retryable transport errors.
                if retryPolicy.shouldRetry(error: mappedError), attempt < maxRetries {
                    attempt += 1
                    try await backoff(attempt: attempt, policy: retryPolicy, response: nil)
                    continue
                }

                // Network-first fallback: stale-tolerant read when connectivity failed.
                if let cache, case let .networkFirst(ttl) = cachePolicy,
                   (mappedError as? KVAPIClientError)?.isNetworkConnectivityError == true,
                   let entry = await cache.entry(for: cacheKey),
                   entry.isFresh(ttl: ttl) {
                    return entry.data
                }

                throw mappedError
            }
        }
    }

    func backoff(attempt: Int, policy: KVRetryPolicy, response: HTTPURLResponse?) async throws {
        let delay = policy.delay(
            forAttempt: attempt,
            retryAfter: response?.value(forHTTPHeaderField: "Retry-After")
        )
        guard delay > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    func interceptRequest(_ request: URLRequest) async throws -> URLRequest {
        var modified = request
        for interceptor in interceptors {
            modified = try await interceptor.intercept(request: modified)
        }
        return modified
    }

    func interceptResponse(data: Data, response: URLResponse) async throws -> (Data, URLResponse) {
        var modifiedData = data
        var modifiedResponse = response
        for interceptor in interceptors {
            let (newResponse, newData) = try await interceptor.intercept(
                response: modifiedResponse,
                data: modifiedData
            )
            modifiedResponse = newResponse ?? modifiedResponse
            modifiedData = newData ?? modifiedData
        }
        return (modifiedData, modifiedResponse)
    }

    /// Asks token-refreshing interceptors whether the request should be retried with fresh credentials.
    func shouldRetryAfterTokenRefresh(response: URLResponse, data: Data) async throws -> Bool {
        for interceptor in interceptors {
            guard let refreshable = interceptor as? KVTokenRefreshingInterceptorProtocol else { continue }
            let action = try await refreshable.refreshAction(response: response, data: data)
            if action == .retryWithUpdatedToken {
                return true
            }
        }
        return false
    }

    func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KVAPIClientError.invalidResponse(data)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Bodies are not assumed to be JSON: a `text/plain` traceback simply has no
            // extractable message and becomes `.statusCode`.
            let errorResponse = KVHTTPErrorResponse(response: httpResponse, data: data)
            if let mapped = errorResponseMapper?(errorResponse) {
                throw KVMappedResponseError(error: mapped)
            }
            throw errorResponse.clientError
        }
    }

    func storeInCache(
        _ data: Data,
        response: URLResponse,
        policy: KVCachePolicy,
        key: String
    ) async {
        guard let cache, policy != .ignore,
              let httpResponse = response as? HTTPURLResponse else { return }

        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                result[key] = value
            }
        }

        await cache.store(
            KVCachedEntry(data: data, statusCode: httpResponse.statusCode, headers: headers),
            for: key
        )
    }

    func mapError(_ error: Error) -> Error {
        if let mapped = error as? KVMappedResponseError {
            return mapped.error
        }
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
                ? KVAPIClientError.timeout
                : KVAPIClientError.networkError(urlError)
        }
        if error is KVAPIClientError || error is DecodingError || error is KVHTTPErrorResponse {
            return error
        }
        return KVAPIClientError.requestFailed(error)
    }
}

/// Carries an error built by ``KVAPIClient/errorResponseMapper`` through `mapError(_:)`
/// untouched, instead of it being wrapped in ``KVAPIClientError/requestFailed(_:)``.
struct KVMappedResponseError: Error {
    let error: any Error
}

// MARK: - Server error message extraction

/// Extracts a human-readable error message from common server error payload shapes.
enum KVServerErrorMessage {
    /// Supported shapes:
    /// `{"message": "..."}`, `{"error": "..."}`, `{"detail": "..."}`,
    /// `{"error_description": "..."}`, `{"error": {"message": "..."}}`,
    /// `{"errors": ["...", ...]}`.
    static func extract(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        for key in ["message", "error", "detail", "error_description"] {
            if let message = object[key] as? String, !message.isEmpty {
                return message
            }
        }

        if let nested = object["error"] as? [String: Any],
           let message = nested["message"] as? String, !message.isEmpty {
            return message
        }

        if let errors = object["errors"] as? [String], let first = errors.first {
            return first
        }

        return nil
    }
}
