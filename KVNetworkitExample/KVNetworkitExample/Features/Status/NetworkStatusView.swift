import SwiftUI
import KVNetworkit

struct NetworkStatusView: View {
    @State private var networkStatus = KVNetworkStatusObject()

    var body: some View {
        NavigationStack {
            List {
                Section("Current Status") {
                    HStack {
                        Image(systemName: networkStatus.isConnected ? "wifi" : "wifi.slash")
                            .foregroundStyle(networkStatus.isConnected ? .green : .red)
                            .font(.title2)
                        VStack(alignment: .leading) {
                            Text(networkStatus.isConnected ? "Connected" : "Offline")
                                .font(.headline)
                            Text(networkStatus.isConnected
                                 ? "Network is available."
                                 : "No network connection.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("About KVNetworkit") {
                    InfoRow(label: "Cache", value: "Hybrid (Memory + Disk)")
                    InfoRow(label: "Retry Policy", value: "Default (2 retries, exp backoff)")
                    InfoRow(label: "Interceptors", value: "Logging, NetworkAware")
                    InfoRow(label: "Cache TTL (list)", value: "60 s (networkFirst)")
                    InfoRow(label: "Cache TTL (detail)", value: "300 s (cacheFirst)")
                }
            }
            .navigationTitle("Status")
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
