import SwiftUI

/// Demonstrates `KVAPIClient` streaming against a real SSE endpoint:
/// rows appear one by one while the request stays open, and Stop cancels it.
struct LiveStreamView: View {
    @State private var vm = LiveStreamViewModel()

    /// Filled in by `StreamStatsInterceptor` when a stream closes — the UI never
    /// computes these numbers itself.
    private var stats = StreamStatsStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if vm.changes.isEmpty {
                    ContentUnavailableView(
                        vm.isStreaming ? "Waiting for events…" : "Not Streaming",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Tap Start to stream live Wikipedia edits over SSE.")
                    )
                } else {
                    List(vm.changes) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(change.title)
                                .font(.headline)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(change.user)
                                Text("·")
                                Text(change.meta.domain)
                                if change.type == "new" {
                                    Text("NEW")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 4)
                                        .background(.tint.opacity(0.15), in: .capsule)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                    .animation(.default, value: vm.changes.count)
                }
            }
            .navigationTitle("Live Stream")
            .safeAreaInset(edge: .bottom) { controls }
            .alert("Stream Error", isPresented: .constant(vm.errorMessage != nil)) {
                Button("OK") { vm.clear() }
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .onDisappear { vm.stop() }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if vm.isStreaming {
                    ProgressView().controlSize(.small)
                }
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(vm.isStreaming ? "Stop" : "Start") {
                    vm.isStreaming ? vm.stop() : vm.start()
                }
                .buttonStyle(.borderedProminent)

                Button("Clear", action: vm.clear)
                    .buttonStyle(.bordered)
                    .disabled(vm.changes.isEmpty)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var statusText: String {
        if vm.isStreaming {
            return "Streaming · \(vm.receivedCount) events"
        }
        // Reported by the stream interceptor, not by the view model.
        return stats.lastSummary.map { "Stopped · \($0)" } ?? "Stopped"
    }
}

#Preview {
    LiveStreamView()
}
