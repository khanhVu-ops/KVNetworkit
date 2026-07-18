import KVNetworkit

/// Shared KVAPIClient configured with logging + network awareness
enum AppNetworkClient {
    static let shared: KVAPIClient = {
        let logging = KVLoggingInterceptor(
            level: .body,
            sensitiveHeaders: ["authorization", "cookie"],
            logsInRelease: false
        )
        let networkGuard = KVNetworkAwareInterceptor(
            networkMonitor: KVNetworkMonitor.shared
        )
        return KVAPIClient(
            interceptors: [networkGuard, logging],
            retryPolicy: .default,
            cache: KVHybridCache()
        )
    }()
}
