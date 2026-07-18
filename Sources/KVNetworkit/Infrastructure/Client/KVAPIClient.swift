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
/// 4. Execute the request, retrying per ``KVRetryPolicy`` with exponential backoff.
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

    /// The retry policy applied to every request.
    public let retryPolicy: KVRetryPolicy

    private let taskManager: any KVTaskManagerProtocol
    private let uploadSessionFactory: @Sendable (any KVUploadProgressDelegateProtocol) -> any KVNetworkSessionProtocol

    // MARK: - Initialization

    /// - Parameters:
    ///   - session: The transport. Defaults to a `URLSession`-backed ``KVNetworkSession``.
    ///   - interceptors: Applied to every request/response in order. Defaults to a ``KVLoggingInterceptor``.
    ///   - retryPolicy: Backoff/retry behavior. Defaults to ``KVRetryPolicy/never``.
    ///   - cache: Optional response cache. Endpoints opt in via ``KVAPIEndpointProtocol/cachePolicy``.
    ///   - taskManager: Tracks in-flight tasks for cancellation. Defaults to a fresh ``KVTaskManager``.
    ///   - uploadSessionFactory: Builds the session used for progress-tracked uploads.
    public init(
        session: any KVNetworkSessionProtocol = KVNetworkSession(),
        interceptors: [any KVNetworkInterceptorProtocol] = [KVLoggingInterceptor()],
        retryPolicy: KVRetryPolicy = .never,
        cache: (any KVNetworkCacheProtocol)? = nil,
        taskManager: any KVTaskManagerProtocol = KVTaskManager(),
        uploadSessionFactory: @escaping @Sendable (any KVUploadProgressDelegateProtocol) -> any KVNetworkSessionProtocol = { delegate in
            KVNetworkSession(requestTimeout: 60, resourceTimeout: 600, delegate: delegate)
        }
    ) {
        self.session = session
        self.interceptors = interceptors
        self.retryPolicy = retryPolicy
        self.cache = cache
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

        return try await executeTracked(id: id) {
            let data = try await self.performRequest(urlRequest, cachePolicy: endpoint.cachePolicy)
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw KVAPIClientError.decodingFailed(error)
            }
        }
    }

    public func request(
        _ endpoint: any KVAPIEndpointProtocol,
        id: String
    ) async throws {
        guard let urlRequest = endpoint.urlRequest else {
            throw KVAPIClientError.invalidURL
        }

        _ = try await executeTracked(id: id) {
            try await self.performRequest(urlRequest, cachePolicy: endpoint.cachePolicy)
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

        return try await executeTracked(id: id) {
            try await self.performRequest(
                urlRequest,
                cachePolicy: endpoint.cachePolicy,
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
    func executeTracked<T>(
        id: String,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        if taskManager.status(for: id) == .inProgress {
            throw KVAPIClientError.taskInProgress
        }

        let task = Task { try await operation() }
        taskManager.register(task, for: id)
        defer { taskManager.complete(id: id) }

        do {
            return try await task.value
        } catch is CancellationError {
            throw KVAPIClientError.taskCanceled
        }
    }
}

// MARK: - Request pipeline

private extension KVAPIClient {

    @discardableResult
    func performRequest(
        _ originalRequest: URLRequest,
        cachePolicy: KVCachePolicy,
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

        let activeSession = progressDelegate.map(uploadSessionFactory) ?? session
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
                        progressDelegate: progressDelegate,
                        hasRefreshedToken: true
                    )
                }

                // 5. Response interceptors.
                let (finalData, finalResponse) = try await interceptResponse(data: data, response: response)

                // 6. Retry on retryable status codes.
                if let http = finalResponse as? HTTPURLResponse,
                   retryPolicy.shouldRetry(statusCode: http.statusCode),
                   attempt < retryPolicy.maxRetries {
                    attempt += 1
                    try await backoff(attempt: attempt)
                    continue
                }

                // 7. Validate and cache.
                try validateResponse(finalResponse, data: finalData)
                await storeInCache(finalData, response: finalResponse, policy: cachePolicy, key: cacheKey)
                return finalData
            } catch {
                if error is CancellationError { throw error }

                let mappedError = mapError(error)

                // Retry on retryable transport errors.
                if retryPolicy.shouldRetry(error: mappedError), attempt < retryPolicy.maxRetries {
                    attempt += 1
                    try await backoff(attempt: attempt)
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

    func backoff(attempt: Int) async throws {
        let delay = retryPolicy.delay(forAttempt: attempt)
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
            if let message = KVServerErrorMessage.extract(from: data) {
                throw KVAPIClientError.serverMessage(message: message, statusCode: httpResponse.statusCode)
            }
            throw KVAPIClientError.statusCode(httpResponse.statusCode)
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
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
                ? KVAPIClientError.timeout
                : KVAPIClientError.networkError(urlError)
        }
        if error is KVAPIClientError || error is DecodingError {
            return error
        }
        return KVAPIClientError.requestFailed(error)
    }
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
