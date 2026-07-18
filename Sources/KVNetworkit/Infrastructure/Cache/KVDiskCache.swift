//
//  KVDiskCache.swift
//  KVNetworkit
//

import Foundation

/// A response cache persisted in the app's caches directory.
///
/// Entries survive app relaunches. The OS may purge the caches directory
/// under storage pressure, so treat the contents as disposable.
///
/// ```swift
/// let client = KVAPIClient(cache: KVDiskCache(name: "api-cache"))
/// ```
public actor KVDiskCache: KVNetworkCacheProtocol {

    private let directory: URL
    private let countLimit: Int
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// - Parameters:
    ///   - name: Subdirectory name inside the caches directory. Defaults to `"KVNetworkitCache"`.
    ///   - countLimit: Maximum number of files kept; oldest are trimmed on store. Defaults to 200.
    public init(name: String = "KVNetworkitCache", countLimit: Int = 200) {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directory = base.appendingPathComponent(name, isDirectory: true)
        self.countLimit = max(1, countLimit)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func entry(for key: String) -> KVCachedEntry? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let entry = try? decoder.decode(KVCachedEntry.self, from: data) else {
            // Corrupt or outdated format — drop it.
            try? fileManager.removeItem(at: url)
            return nil
        }
        return entry
    }

    public func store(_ entry: KVCachedEntry, for key: String) {
        guard let data = try? encoder.encode(entry) else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
        trimIfNeeded()
    }

    public func removeEntry(for key: String) {
        try? fileManager.removeItem(at: fileURL(for: key))
    }

    public func removeAll() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Private

    private func fileURL(for key: String) -> URL {
        // Keys from KVCacheKey are already hex digests and filesystem-safe.
        directory.appendingPathComponent(key).appendingPathExtension("cache")
    }

    private func trimIfNeeded() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ), files.count > countLimit else { return }

        let sortedByAge = files.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }

        for file in sortedByAge.prefix(files.count - countLimit) {
            try? fileManager.removeItem(at: file)
        }
    }
}
