//
//  KVRequestTimeoutInterceptor.swift
//  KVNetworkit
//

import Foundation

/// Overrides the timeout interval of every request.
///
/// Note that `URLSessionConfiguration.timeoutIntervalForRequest` still applies
/// as an upper bound; configure the session (``KVNetworkSession``) accordingly
/// when using long timeouts here.
public struct KVRequestTimeoutInterceptor: KVNetworkInterceptorProtocol {

    private let timeout: TimeInterval

    /// - Parameter timeout: Timeout in seconds applied to each request.
    public init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    public func intercept(request: URLRequest) async throws -> URLRequest {
        var modified = request
        modified.timeoutInterval = timeout
        return modified
    }
}
