import Foundation
import KVNetworkit

/// Consumes a live `text/event-stream` endpoint with `KVAPIClient.stream(_:as:)`.
///
/// The whole streaming story is the `start()` method below: open the stream, append
/// each decoded event as it lands, and cancel by id.
@Observable
@MainActor
final class LiveStreamViewModel {

    /// Newest first, capped — a live stream never ends, so the buffer must not grow forever.
    private(set) var changes: [RecentChange] = []
    private(set) var isStreaming = false
    private(set) var receivedCount = 0
    private(set) var errorMessage: String?

    private static let maxRows = 50
    private let streamId = "wikimedia-recentchange"

    private let client: KVAPIClient
    private var streamTask: Task<Void, Never>?

    /// The default is resolved inside the initializer rather than as a default argument:
    /// `AppNetworkClient.shared` is main-actor isolated, and default arguments are
    /// evaluated at the (possibly nonisolated) call site.
    init(client: KVAPIClient? = nil) {
        self.client = client ?? AppNetworkClient.shared
    }

    func start() {
        guard !isStreaming else { return }

        isStreaming = true
        errorMessage = nil

        streamTask = Task {
            do {
                // Throws here — before the first event — if the response is not a 2xx,
                // carrying the server's own message when it sent one.
                let stream = try await client.stream(
                    WikiStreamEndpoint.recentChanges,
                    as: RecentChange.self,
                    id: streamId
                )

                for try await change in stream {
                    guard change.isHumanEdit else { continue }
                    append(change)
                }
                isStreaming = false
            } catch KVAPIClientError.taskCanceled {
                isStreaming = false
            } catch is CancellationError {
                isStreaming = false
            } catch {
                errorMessage = error.localizedDescription
                isStreaming = false
            }
        }
    }

    func stop() {
        // Cancelling by id ends the stream from the client side; the task's
        // `for try await` then exits through the `taskCanceled` branch above.
        client.cancelRequest(with: streamId)
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    func clear() {
        changes.removeAll()
        receivedCount = 0
        errorMessage = nil
    }

    private func append(_ change: RecentChange) {
        receivedCount += 1
        changes.insert(change, at: 0)
        if changes.count > Self.maxRows {
            changes.removeLast(changes.count - Self.maxRows)
        }
    }
}
