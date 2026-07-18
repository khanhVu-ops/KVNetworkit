//
//  KVHeaderInjectorInterceptor.swift
//  KVNetworkit
//

import Foundation

/// Adds a fixed set of headers to every request.
///
/// Useful for common headers such as `User-Agent`, `Accept-Language`,
/// app version or platform markers.
///
/// ```swift
/// KVHeaderInjectorInterceptor(headers: [
///     "X-App-Version": Bundle.main.appVersion,
///     "X-Platform": "ios"
/// ])
/// ```
public struct KVHeaderInjectorInterceptor: KVNetworkInterceptorProtocol {

    private let headers: [String: String]
    private let overridesExisting: Bool

    /// - Parameters:
    ///   - headers: Headers to inject.
    ///   - overridesExisting: Replace headers the request already has. Defaults to `false`.
    public init(headers: [String: String], overridesExisting: Bool = false) {
        self.headers = headers
        self.overridesExisting = overridesExisting
    }

    public func intercept(request: URLRequest) async throws -> URLRequest {
        var modified = request
        for (key, value) in headers {
            if overridesExisting || modified.value(forHTTPHeaderField: key) == nil {
                modified.setValue(value, forHTTPHeaderField: key)
            }
        }
        return modified
    }
}
