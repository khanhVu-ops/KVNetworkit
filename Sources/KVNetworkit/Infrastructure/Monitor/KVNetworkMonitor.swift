//
//  KVNetworkMonitor.swift
//  KVNetworkit
//

import Foundation
import Network
import Combine

/// `NWPathMonitor`-backed implementation of ``KVNetworkMonitorProtocol``.
///
/// Starts monitoring immediately on creation. Use ``shared`` for the common case;
/// create instances only when you need independent monitors (e.g. tests).
public final class KVNetworkMonitor: KVNetworkMonitorProtocol, @unchecked Sendable {

    /// Shared monitor for app-wide connectivity state.
    public static let shared = KVNetworkMonitor()

    private let queue = DispatchQueue(label: "com.kvnetworkit.networkmonitor")
    private let subject: CurrentValueSubject<Bool, Never>
    private let lock = NSLock()
    private var monitor: NWPathMonitor

    public init() {
        // Assume reachable until the first path update arrives, so app-launch
        // requests aren't rejected before the monitor warms up.
        self.subject = CurrentValueSubject(true)
        self.monitor = NWPathMonitor()
        start(monitor)
    }

    deinit {
        monitor.cancel()
    }

    public var isNetworkAvailable: Bool {
        subject.value
    }

    public var isNetworkAvailablePublisher: AnyPublisher<Bool, Never> {
        subject.removeDuplicates().eraseToAnyPublisher()
    }

    public func forceRefresh() {
        lock.lock()
        defer { lock.unlock() }
        monitor.cancel()
        monitor = NWPathMonitor()
        start(monitor)
    }

    private func start(_ monitor: NWPathMonitor) {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.subject.send(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }
}
