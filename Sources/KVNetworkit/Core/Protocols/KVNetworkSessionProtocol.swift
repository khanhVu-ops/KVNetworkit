//
//  KVNetworkSessionProtocol.swift
//  KVNetworkit
//

import Foundation

/// An async sequence of response body chunks, as they arrive off the network.
///
/// Chunks carry no framing guarantees: a chunk may hold several events, part of
/// one, or a fragment of a multi-byte character. Use ``KVSSEParser`` or
/// ``KVLineAccumulator`` to reassemble them.
public typealias KVDataStream = AsyncThrowingStream<Data, any Error>

/// Abstracts `URLSession` so it can be replaced in tests.
public protocol KVNetworkSessionProtocol: Sendable {
    /// Performs a network request and returns the response data.
    ///
    /// - Parameter request: The `URLRequest` to execute.
    /// - Returns: A tuple containing the response `Data` and the associated `URLResponse`.
    /// - Throws: An error if the network request fails.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)

    /// Performs a request and returns the response body incrementally.
    ///
    /// Returns as soon as the response head is available, before the body has been
    /// received — that is what makes progressive rendering of a long-lived
    /// response (SSE, NDJSON) possible.
    ///
    /// - Returns: The body chunk stream and the `URLResponse`.
    /// - Throws: An error if the connection could not be established.
    func bytes(for request: URLRequest) async throws -> (KVDataStream, URLResponse)
}

public extension KVNetworkSessionProtocol {
    /// Non-streaming fallback: buffers the whole body, then emits it as one chunk.
    ///
    /// This keeps existing conformers (custom transports, test doubles) source
    /// compatible. Results are correct but not incremental, so any conformer used
    /// for real streaming should override it.
    func bytes(for request: URLRequest) async throws -> (KVDataStream, URLResponse) {
        let (data, response) = try await data(for: request)
        let stream = KVDataStream { continuation in
            if !data.isEmpty { continuation.yield(data) }
            continuation.finish()
        }
        return (stream, response)
    }
}
