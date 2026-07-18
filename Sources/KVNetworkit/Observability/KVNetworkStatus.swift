//
//  KVNetworkStatus.swift
//  KVNetworkit
//

import Foundation
import Combine
#if canImport(Observation)
import Observation
#endif

// KVNetworkit supports both SwiftUI observation systems:
//
// - iOS 17+ — ``KVNetworkStatusModel`` (`@Observable`): views re-render only
//   when properties they actually read change. Prefer it when available.
// - iOS 16  — ``KVNetworkStatusObject`` (`ObservableObject`): classic
//   `@Published`-driven updates.
//
// Branch at the view level:
//
// ```swift
// struct RootView: View {
//     var body: some View {
//         content
//             .overlay(alignment: .top) {
//                 if #available(iOS 17.0, *) {
//                     ModernOfflineBanner()   // uses KVNetworkStatusModel
//                 } else {
//                     LegacyOfflineBanner()   // uses KVNetworkStatusObject
//                 }
//             }
//     }
// }
//
// @available(iOS 17.0, *)
// struct ModernOfflineBanner: View {
//     @State private var status = KVNetworkStatusModel()
//     var body: some View {
//         if !status.isConnected { OfflineLabel() }
//     }
// }
//
// struct LegacyOfflineBanner: View {
//     @StateObject private var status = KVNetworkStatusObject()
//     var body: some View {
//         if !status.isConnected { OfflineLabel() }
//     }
// }
// ```

/// Observable network connectivity state for iOS 17+ using the `Observation` framework.
///
/// More efficient than `ObservableObject`: SwiftUI tracks per-property reads,
/// so only views that read `isConnected` re-render.
@available(iOS 17.0, macOS 14.0, *)
@Observable
public final class KVNetworkStatusModel {

    /// Whether the device currently has network connectivity.
    public private(set) var isConnected: Bool

    @ObservationIgnored
    private var cancellable: AnyCancellable?

    /// - Parameter monitor: The connectivity source. Defaults to ``KVNetworkMonitor/shared``.
    public init(monitor: any KVNetworkMonitorProtocol = KVNetworkMonitor.shared) {
        self.isConnected = monitor.isNetworkAvailable
        self.cancellable = monitor.isNetworkAvailablePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAvailable in
                self?.isConnected = isAvailable
            }
    }
}

/// Observable network connectivity state for iOS 16 using `ObservableObject`.
///
/// On iOS 17+ prefer ``KVNetworkStatusModel`` for better rendering performance.
public final class KVNetworkStatusObject: ObservableObject {

    /// Whether the device currently has network connectivity.
    @Published public private(set) var isConnected: Bool

    private var cancellable: AnyCancellable?

    /// - Parameter monitor: The connectivity source. Defaults to ``KVNetworkMonitor/shared``.
    public init(monitor: any KVNetworkMonitorProtocol = KVNetworkMonitor.shared) {
        self.isConnected = monitor.isNetworkAvailable
        self.cancellable = monitor.isNetworkAvailablePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAvailable in
                self?.isConnected = isAvailable
            }
    }
}
