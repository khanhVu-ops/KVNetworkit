//
//  KVMockNetworkInterceptor.swift
//  KVNetworkit
//

import Foundation

/// A ``KVNetworkInterceptorProtocol`` mock whose behavior is driven by closures.
///
/// ```swift
/// let interceptor = KVMockNetworkInterceptor(
///     requestModifier: { request in
///         var request = request
///         request.setValue("mock", forHTTPHeaderField: "X-Test")
///         return request
///     }
/// )
/// ```
public final class KVMockNetworkInterceptor: KVNetworkInterceptorProtocol, @unchecked Sendable {

    private let requestModifier: (@Sendable (URLRequest) throws -> URLRequest)?
    private let responseModifier: (@Sendable (URLResponse?, Data?) throws -> (URLResponse?, Data?))?

    public init(
        requestModifier: (@Sendable (URLRequest) throws -> URLRequest)? = nil,
        responseModifier: (@Sendable (URLResponse?, Data?) throws -> (URLResponse?, Data?))? = nil
    ) {
        self.requestModifier = requestModifier
        self.responseModifier = responseModifier
    }

    public func intercept(request: URLRequest) async throws -> URLRequest {
        try requestModifier?(request) ?? request
    }

    public func intercept(response: URLResponse?, data: Data?) async throws -> (URLResponse?, Data?) {
        try responseModifier?(response, data) ?? (response, data)
    }
}
