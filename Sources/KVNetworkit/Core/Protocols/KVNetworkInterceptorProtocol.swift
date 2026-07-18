//
//  KVNetworkInterceptorProtocol.swift
//  KVNetworkit
//

import Foundation

/// A hook that can inspect or modify requests before they are sent and
/// responses before they are returned to the caller.
///
/// Interceptors run in the order they were passed to ``KVAPIClient``:
/// requests flow through them first-to-last, responses first-to-last as well.
///
/// Both methods have default no-op implementations, so a conformer only
/// implements the side it cares about:
///
/// ```swift
/// struct LanguageInterceptor: KVNetworkInterceptorProtocol {
///     func intercept(request: URLRequest) async throws -> URLRequest {
///         var request = request
///         request.setValue(Locale.current.identifier, forHTTPHeaderField: "Accept-Language")
///         return request
///     }
/// }
/// ```
///
/// Common use cases: authentication headers, logging, connectivity checks,
/// custom headers, response rewriting.
public protocol KVNetworkInterceptorProtocol: Sendable {
    /// Inspects or modifies an outgoing request. Throwing aborts the request.
    func intercept(request: URLRequest) async throws -> URLRequest

    /// Inspects or modifies an incoming response. Throwing fails the request.
    func intercept(response: URLResponse?, data: Data?) async throws -> (URLResponse?, Data?)
}

public extension KVNetworkInterceptorProtocol {
    func intercept(request: URLRequest) async throws -> URLRequest {
        request
    }

    func intercept(response: URLResponse?, data: Data?) async throws -> (URLResponse?, Data?) {
        (response, data)
    }
}
