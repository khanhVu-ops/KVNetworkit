//
//  KVNetworkCacheProtocol.swift
//  KVNetworkit
//

import Foundation
import CryptoKit

/// A cached HTTP response.
public struct KVCachedEntry: Codable, Sendable, Equatable {
    /// The response body.
    public let data: Data

    /// The HTTP status code of the original response.
    public let statusCode: Int

    /// Selected response headers of the original response.
    public let headers: [String: String]

    /// When the entry was stored.
    public let createdAt: Date

    public init(data: Data, statusCode: Int, headers: [String: String] = [:], createdAt: Date = Date()) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.createdAt = createdAt
    }

    /// Whether the entry is still within its time-to-live.
    public func isFresh(ttl: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) < ttl
    }
}

/// Storage backend for cached responses.
///
/// KVNetworkit ships three implementations:
/// - ``KVMemoryCache`` — fast, in-memory LRU; cleared when the app terminates.
/// - ``KVDiskCache`` — persists across launches in the caches directory.
/// - ``KVHybridCache`` — memory in front of disk.
///
/// Conform your own type to plug in a different backend (e.g. a database).
public protocol KVNetworkCacheProtocol: Sendable {
    /// Returns the entry stored for the key, or `nil`.
    func entry(for key: String) async -> KVCachedEntry?

    /// Stores an entry for the key, replacing any existing entry.
    func store(_ entry: KVCachedEntry, for key: String) async

    /// Removes the entry for the key.
    func removeEntry(for key: String) async

    /// Removes all entries.
    func removeAll() async
}

/// Builds stable cache keys for requests.
public enum KVCacheKey {
    /// A stable key derived from the request's method, URL and body.
    ///
    /// Headers are deliberately excluded so the key survives token rotation.
    public static func make(for request: URLRequest) -> String {
        var hasher = SHA256()
        hasher.update(data: Data((request.httpMethod ?? "GET").utf8))
        hasher.update(data: Data((request.url?.absoluteString ?? "").utf8))
        if let body = request.httpBody {
            hasher.update(data: body)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
