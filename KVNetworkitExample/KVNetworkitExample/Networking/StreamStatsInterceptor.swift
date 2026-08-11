import Foundation
import KVNetworkit

/// Holds the summary of the most recently finished stream, for display in the UI.
@Observable
@MainActor
final class StreamStatsStore {
    static let shared = StreamStatsStore()

    var lastSummary: String?

    private init() {}
}

/// Demonstrates `KVStreamInterceptorProtocol`: observe a streaming body without
/// touching the code that consumes it.
///
/// `streamDidOpen` and `stream(id:didReceive:)` are left at their no-op defaults —
/// only the closing summary is needed here.
struct StreamStatsInterceptor: KVStreamInterceptorProtocol {

    func streamDidClose(id: String, statistics: KVStreamStatistics, error: (any Error)?) async {
        let kilobytes = Double(statistics.byteCount) / 1024
        let summary = String(
            format: "%d chunks · %.1f KB · %.1fs%@",
            statistics.chunkCount,
            kilobytes,
            statistics.duration,
            error == nil ? "" : " · ended early"
        )

        await MainActor.run {
            StreamStatsStore.shared.lastSummary = summary
        }
    }
}
