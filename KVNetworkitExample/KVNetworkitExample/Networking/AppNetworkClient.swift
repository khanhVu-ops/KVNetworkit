import KVNetworkit

/// Shared KVAPIClient configured with logging + network awareness
enum AppNetworkClient {
    static let shared: KVAPIClient = {
        let logging = KVLoggingInterceptor(
            level: .body,
            sensitiveHeaders: ["authorization", "cookie"],
            logsInRelease: false,
            // The demo stream (Wikimedia recentchange) never ends and carries large
            // payloads, so only its open/close lines are logged. Chat-style streams that
            // do end are better served by the default `.aggregated`, which prints the
            // whole body once on close.
            streamBodyLogging: .none
        )
        let networkGuard = KVNetworkAwareInterceptor(
            networkMonitor: KVNetworkMonitor.shared
        )
        return KVAPIClient(
            interceptors: [networkGuard, logging, StreamStatsInterceptor()],
            retryPolicy: .default,
            cache: KVHybridCache()
        )
    }()
}
