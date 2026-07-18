//
//  KVMemoryCache.swift
//  KVNetworkit
//

import Foundation

/// An in-memory LRU response cache.
///
/// Fast and allocation-cheap; contents are lost when the process terminates.
/// When `countLimit` is exceeded, the least-recently-used entry is evicted.
///
/// ```swift
/// let client = KVAPIClient(cache: KVMemoryCache(countLimit: 200))
/// ```
public actor KVMemoryCache: KVNetworkCacheProtocol {

    private var storage: [String: KVCachedEntry] = [:]
    /// Keys ordered by recency of use — most recently used last.
    private var accessOrder: [String] = []
    private let countLimit: Int

    /// - Parameter countLimit: Maximum number of entries kept. Defaults to 100.
    public init(countLimit: Int = 100) {
        self.countLimit = max(1, countLimit)
    }

    public func entry(for key: String) -> KVCachedEntry? {
        guard let entry = storage[key] else { return nil }
        touch(key)
        return entry
    }

    public func store(_ entry: KVCachedEntry, for key: String) {
        storage[key] = entry
        touch(key)
        evictIfNeeded()
    }

    public func removeEntry(for key: String) {
        storage.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }
    }

    public func removeAll() {
        storage.removeAll()
        accessOrder.removeAll()
    }

    /// The number of entries currently stored.
    public var count: Int { storage.count }

    // MARK: - Private

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func evictIfNeeded() {
        while storage.count > countLimit, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }
}
