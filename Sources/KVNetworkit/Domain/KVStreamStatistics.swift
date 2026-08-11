//
//  KVStreamStatistics.swift
//  KVNetworkit
//

import Foundation

/// What a stream delivered, reported to ``KVStreamInterceptorProtocol`` when it closes.
public struct KVStreamStatistics: Sendable, Equatable {

    /// Number of body chunks handed to the consumer.
    public let chunkCount: Int

    /// Total bytes handed to the consumer — counted *after* any interceptor
    /// transformed the chunk, so it matches what the caller actually read.
    public let byteCount: Int

    /// Seconds between the response head arriving and the stream closing.
    public let duration: TimeInterval

    public init(chunkCount: Int, byteCount: Int, duration: TimeInterval) {
        self.chunkCount = chunkCount
        self.byteCount = byteCount
        self.duration = duration
    }
}
