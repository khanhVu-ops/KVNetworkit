//
//  KVStreamInterceptorProtocol.swift
//  KVNetworkit
//

import Foundation

/// An interceptor that also observes the *body* of a streaming response.
///
/// ``KVNetworkInterceptorProtocol/intercept(response:data:)`` is called with the
/// response head and `nil` data for a stream — the body has not arrived yet, and
/// with a long-lived response it never arrives "all at once". Conform to this
/// protocol to see the chunks as they flow.
///
/// ``KVAPIClient`` discovers conformers among its regular interceptors, so a single
/// instance can handle both plain requests and streams:
///
/// ```swift
/// struct StreamMetricsInterceptor: KVStreamInterceptorProtocol {
///     func streamDidClose(id: String, statistics: KVStreamStatistics, error: (any Error)?) async {
///         analytics.record(
///             chunks: statistics.chunkCount,
///             bytes: statistics.byteCount,
///             seconds: statistics.duration,
///             failed: error != nil
///         )
///     }
/// }
///
/// let client = KVAPIClient(interceptors: [KVLoggingInterceptor(), StreamMetricsInterceptor()])
/// ```
///
/// All three methods have no-op defaults, so implement only the ones you need.
/// Interceptors run in the order they were passed to the client.
///
/// The `id` is the request identifier passed to `stream(_:accept:id:)` — the same one
/// `cancelRequest(with:)` takes. Use it to key per-stream state when one interceptor
/// instance serves several concurrent streams.
public protocol KVStreamInterceptorProtocol: KVNetworkInterceptorProtocol {

    /// Called once, after the response head passed status validation and before the
    /// first chunk reaches the consumer.
    func streamDidOpen(id: String, response: URLResponse) async

    /// Called for every body chunk, before the consumer receives it.
    ///
    /// - Returns: Replacement data, or `nil` to pass the chunk through unchanged.
    ///   Transforming is allowed but affects what the parser downstream sees — do not
    ///   reshape a chunk unless you mean to (dropping bytes breaks event framing).
    /// - Throws: Fails the stream with the thrown error, same as a response interceptor.
    func stream(id: String, didReceive chunk: Data) async throws -> Data?

    /// Called once when the stream ends, whichever way it ended.
    ///
    /// - Parameter error: `nil` on clean completion, ``KVAPIClientError/taskCanceled``
    ///   when cancelled, otherwise the failure that ended the stream.
    func streamDidClose(id: String, statistics: KVStreamStatistics, error: (any Error)?) async
}

public extension KVStreamInterceptorProtocol {
    func streamDidOpen(id: String, response: URLResponse) async {}

    func stream(id: String, didReceive chunk: Data) async throws -> Data? { nil }

    func streamDidClose(id: String, statistics: KVStreamStatistics, error: (any Error)?) async {}
}
