//
//  KVHybridCache.swift
//  KVNetworkit
//

import Foundation

/// A two-tier cache: fast in-memory lookups backed by persistent disk storage.
///
/// Reads hit memory first and fall back to disk (promoting the entry back
/// into memory). Writes go to both tiers.
///
/// ```swift
/// let client = KVAPIClient(cache: KVHybridCache())
/// ```
public final class KVHybridCache: KVNetworkCacheProtocol {

    private let memory: KVMemoryCache
    private let disk: KVDiskCache

    /// - Parameters:
    ///   - memory: The in-memory tier. Defaults to a 100-entry ``KVMemoryCache``.
    ///   - disk: The persistent tier. Defaults to a 200-entry ``KVDiskCache``.
    public init(
        memory: KVMemoryCache = KVMemoryCache(),
        disk: KVDiskCache = KVDiskCache()
    ) {
        self.memory = memory
        self.disk = disk
    }

    public func entry(for key: String) async -> KVCachedEntry? {
        if let entry = await memory.entry(for: key) {
            return entry
        }
        if let entry = await disk.entry(for: key) {
            await memory.store(entry, for: key)
            return entry
        }
        return nil
    }

    public func store(_ entry: KVCachedEntry, for key: String) async {
        await memory.store(entry, for: key)
        await disk.store(entry, for: key)
    }

    public func removeEntry(for key: String) async {
        await memory.removeEntry(for: key)
        await disk.removeEntry(for: key)
    }

    public func removeAll() async {
        await memory.removeAll()
        await disk.removeAll()
    }
}
