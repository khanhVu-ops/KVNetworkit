//
//  KVTokenRefreshingInterceptorProtocol.swift
//  KVNetworkit
//

import Foundation

/// An action a token-refreshing interceptor asks the client to take after
/// inspecting a response.
public enum KVInterceptorAction: Sendable, Equatable {
    /// Continue processing the response as normal.
    case proceed

    /// Credentials were refreshed — retry the original request with updated tokens.
    /// ``KVAPIClient`` retries at most once per logical request to prevent refresh loops.
    case retryWithUpdatedToken
}

/// An interceptor that can refresh authentication tokens when a response
/// indicates expired credentials (typically 401).
///
/// ```swift
/// struct TokenRefreshInterceptor: KVTokenRefreshingInterceptorProtocol {
///     let tokenStore: any KVAuthTokenStoreProviding
///     let refresher: KVTokenRefreshCoordinator
///
///     func refreshAction(response: URLResponse?, data: Data?) async throws -> KVInterceptorAction {
///         guard (response as? HTTPURLResponse)?.statusCode == 401,
///               tokenStore.refreshToken != nil else { return .proceed }
///
///         try await refresher.refresh {
///             // call your refresh endpoint, then:
///             // tokenStore.setAccessToken(newToken)
///         }
///         return .retryWithUpdatedToken
///     }
/// }
/// ```
public protocol KVTokenRefreshingInterceptorProtocol: KVNetworkInterceptorProtocol {
    /// Inspects a response and decides whether the client should retry after a token refresh.
    ///
    /// Throw ``KVAPIClientError/refreshTokenInvalid`` when the refresh itself fails
    /// so the app can trigger a logout.
    func refreshAction(response: URLResponse?, data: Data?) async throws -> KVInterceptorAction
}

/// Deduplicates concurrent token refreshes: when several requests hit 401 at
/// the same time, only one refresh runs and the rest await its result.
///
/// Keep one coordinator per token store and share it across interceptors.
public actor KVTokenRefreshCoordinator {

    private var inFlight: Task<Void, Error>?

    public init() {}

    /// Runs `operation`, or joins an already-running refresh instead of starting another.
    public func refresh(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task { try await operation() }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }
}
