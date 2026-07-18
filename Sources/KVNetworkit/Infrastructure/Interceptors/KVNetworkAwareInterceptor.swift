//
//  KVNetworkAwareInterceptor.swift
//  KVNetworkit
//

import Foundation

/// Fails fast with ``KVAPIClientError/networkUnavailable`` when the device is offline,
/// instead of waiting for a transport timeout.
///
/// When the monitor reports "offline", the interceptor forces one monitor refresh
/// and re-checks after a short grace period — path monitors occasionally report
/// stale state, especially in simulators.
///
/// - Important: `networkUnavailable` is a connectivity error
///   (see ``KVAPIClientError/isNetworkConnectivityError``) — do not log users out on it.
public struct KVNetworkAwareInterceptor: KVNetworkInterceptorProtocol {

    private let networkMonitor: any KVNetworkMonitorProtocol
    private let refreshGracePeriod: TimeInterval

    /// - Parameters:
    ///   - networkMonitor: The connectivity source. Defaults to ``KVNetworkMonitor/shared``.
    ///   - refreshGracePeriod: Seconds to wait after a forced refresh before re-checking. Defaults to 0.5.
    public init(
        networkMonitor: any KVNetworkMonitorProtocol = KVNetworkMonitor.shared,
        refreshGracePeriod: TimeInterval = 0.5
    ) {
        self.networkMonitor = networkMonitor
        self.refreshGracePeriod = refreshGracePeriod
    }

    public func intercept(request: URLRequest) async throws -> URLRequest {
        guard !networkMonitor.isNetworkAvailable else { return request }

        // The monitor may be stuck — refresh once and re-check.
        networkMonitor.forceRefresh()
        try await Task.sleep(nanoseconds: UInt64(refreshGracePeriod * 1_000_000_000))

        guard networkMonitor.isNetworkAvailable else {
            throw KVAPIClientError.networkUnavailable
        }
        return request
    }
}
