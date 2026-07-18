//
//  KVNetworkMonitorProtocol.swift
//  KVNetworkit
//

import Foundation
import Combine

/// Reports device network connectivity and publishes changes.
///
/// Inject into interceptors (see ``KVNetworkAwareInterceptor``) or observe
/// from the UI via ``KVNetworkStatusModel`` / ``KVNetworkStatusObject``.
public protocol KVNetworkMonitorProtocol: Sendable {
    /// Whether the network is currently available.
    var isNetworkAvailable: Bool { get }

    /// Emits whenever network availability changes.
    var isNetworkAvailablePublisher: AnyPublisher<Bool, Never> { get }

    /// Restarts the underlying path monitor. Useful when state detection
    /// gets stuck, especially in simulators.
    func forceRefresh()
}
