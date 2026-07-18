//
//  KVNetworkSession.swift
//  KVNetworkit
//

import Foundation

/// Default `URLSession`-backed implementation of ``KVNetworkSessionProtocol``.
public final class KVNetworkSession: KVNetworkSessionProtocol, @unchecked Sendable {

    private let session: URLSession

    /// Creates a session with the given timeouts.
    ///
    /// - Parameters:
    ///   - requestTimeout: Timeout for a single request (seconds). Defaults to 60.
    ///   - resourceTimeout: Timeout for the whole transfer, relevant for uploads/downloads. Defaults to 300.
    ///   - delegate: Optional `URLSessionDelegate` (e.g. for upload progress or pinning).
    ///   - configuration: Base configuration. Defaults to `.default`.
    ///     `URLCache` is disabled because caching is handled explicitly by ``KVAPIClient``.
    public init(
        requestTimeout: TimeInterval = 60,
        resourceTimeout: TimeInterval = 300,
        delegate: URLSessionDelegate? = nil,
        configuration: URLSessionConfiguration = .default
    ) {
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Wraps a pre-configured `URLSession`.
    public init(session: URLSession) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
