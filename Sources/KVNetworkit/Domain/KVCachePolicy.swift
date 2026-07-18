//
//  KVCachePolicy.swift
//  KVNetworkit
//

import Foundation

/// Controls how a request interacts with the client's response cache.
///
/// The policy is declared per endpoint via ``KVAPIEndpointProtocol/cachePolicy``
/// and only takes effect when the ``KVAPIClient`` was created with a cache.
///
/// ```swift
/// var cachePolicy: KVCachePolicy { .cacheFirst(ttl: 300) } // serve from cache for 5 minutes
/// ```
public enum KVCachePolicy: Sendable, Equatable {
    /// Never read from or write to the cache. This is the default.
    case ignore

    /// Return a cached response if one exists and is younger than `ttl`;
    /// otherwise perform the network request and cache the result.
    ///
    /// Best for data that changes rarely (catalogs, configuration, profiles).
    case cacheFirst(ttl: TimeInterval)

    /// Always perform the network request and cache the result. If the request
    /// fails with a connectivity error, fall back to a cached response younger than `ttl`.
    ///
    /// Best for data that should be fresh but where stale data beats an error screen.
    case networkFirst(ttl: TimeInterval)

    /// Always perform the network request and cache the result, never read from the cache.
    /// Useful to refresh entries that other `cacheFirst` endpoints will read.
    case refresh
}
