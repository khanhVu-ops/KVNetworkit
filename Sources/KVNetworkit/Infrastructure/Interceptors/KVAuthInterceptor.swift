//
//  KVAuthInterceptor.swift
//  KVNetworkit
//

import Foundation

/// Injects a `Bearer` token into the `Authorization` header of every request.
///
/// The token is read lazily per request, so rotated tokens are picked up
/// automatically.
///
/// ```swift
/// let auth = KVAuthInterceptor(tokenProvider: { tokenStore.accessToken })
/// let client = KVAPIClient(interceptors: [auth, KVLoggingInterceptor()])
/// ```
public struct KVAuthInterceptor: KVNetworkInterceptorProtocol {

    private let tokenProvider: @Sendable () -> String?
    private let headerField: String
    private let prefix: String

    /// - Parameters:
    ///   - tokenProvider: Returns the current access token, or `nil` to leave the request untouched.
    ///   - headerField: Header to set. Defaults to `"Authorization"`.
    ///   - prefix: Value prefix. Defaults to `"Bearer "`.
    public init(
        tokenProvider: @escaping @Sendable () -> String?,
        headerField: String = "Authorization",
        prefix: String = "Bearer "
    ) {
        self.tokenProvider = tokenProvider
        self.headerField = headerField
        self.prefix = prefix
    }

    /// Convenience initializer reading from a ``KVAuthTokenStoreProviding``.
    public init(tokenStore: any KVAuthTokenStoreProviding) {
        self.init(tokenProvider: { tokenStore.accessToken })
    }

    public func intercept(request: URLRequest) async throws -> URLRequest {
        guard let token = tokenProvider() else { return request }
        var modified = request
        modified.setValue(prefix + token, forHTTPHeaderField: headerField)
        return modified
    }
}
