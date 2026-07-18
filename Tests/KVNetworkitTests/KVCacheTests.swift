//
//  KVCacheTests.swift
//  KVNetworkitTests
//

import XCTest
@testable import KVNetworkit

final class KVCacheTests: XCTestCase {

    private func makeEntry(_ text: String = "hello", age: TimeInterval = 0) -> KVCachedEntry {
        KVCachedEntry(
            data: Data(text.utf8),
            statusCode: 200,
            createdAt: Date().addingTimeInterval(-age)
        )
    }

    // MARK: - Freshness

    func testEntryFreshness() {
        XCTAssertTrue(makeEntry(age: 10).isFresh(ttl: 60))
        XCTAssertFalse(makeEntry(age: 120).isFresh(ttl: 60))
    }

    // MARK: - Memory cache

    func testMemoryCacheStoreAndFetch() async {
        let cache = KVMemoryCache()
        await cache.store(makeEntry(), for: "key")
        let entry = await cache.entry(for: "key")
        XCTAssertEqual(entry?.data, Data("hello".utf8))
    }

    func testMemoryCacheEvictsLeastRecentlyUsed() async {
        let cache = KVMemoryCache(countLimit: 2)
        await cache.store(makeEntry("a"), for: "a")
        await cache.store(makeEntry("b"), for: "b")

        // Touch "a" so "b" becomes least recently used.
        _ = await cache.entry(for: "a")
        await cache.store(makeEntry("c"), for: "c")

        let a = await cache.entry(for: "a")
        let b = await cache.entry(for: "b")
        let c = await cache.entry(for: "c")
        XCTAssertNotNil(a)
        XCTAssertNil(b)
        XCTAssertNotNil(c)
    }

    func testMemoryCacheRemoveAll() async {
        let cache = KVMemoryCache()
        await cache.store(makeEntry(), for: "key")
        await cache.removeAll()
        let entry = await cache.entry(for: "key")
        XCTAssertNil(entry)
        let count = await cache.count
        XCTAssertEqual(count, 0)
    }

    // MARK: - Disk cache

    func testDiskCacheRoundTrip() async {
        let cache = KVDiskCache(name: "KVNetworkitTests-\(UUID().uuidString)")
        let key = KVCacheKey.make(for: URLRequest(url: URL(string: "https://example.com/a")!))

        await cache.store(makeEntry("persisted"), for: key)
        let entry = await cache.entry(for: key)
        XCTAssertEqual(entry?.data, Data("persisted".utf8))
        XCTAssertEqual(entry?.statusCode, 200)

        await cache.removeAll()
        let removed = await cache.entry(for: key)
        XCTAssertNil(removed)
    }

    // MARK: - Hybrid cache

    func testHybridCachePromotesDiskHitsToMemory() async {
        let memory = KVMemoryCache()
        let disk = KVDiskCache(name: "KVNetworkitTests-\(UUID().uuidString)")
        let hybrid = KVHybridCache(memory: memory, disk: disk)

        // Seed only the disk tier.
        await disk.store(makeEntry("disk-only"), for: "key")
        let memoryMissBefore = await memory.entry(for: "key")
        XCTAssertNil(memoryMissBefore)

        let entry = await hybrid.entry(for: "key")
        XCTAssertEqual(entry?.data, Data("disk-only".utf8))

        // The hit must have been promoted to memory.
        let promoted = await memory.entry(for: "key")
        XCTAssertNotNil(promoted)

        await hybrid.removeAll()
    }

    // MARK: - Cache keys

    func testCacheKeyIsStableAndIgnoresHeaders() {
        var request1 = URLRequest(url: URL(string: "https://example.com/a?x=1")!)
        request1.httpMethod = "GET"
        request1.setValue("Bearer token-1", forHTTPHeaderField: "Authorization")

        var request2 = URLRequest(url: URL(string: "https://example.com/a?x=1")!)
        request2.httpMethod = "GET"
        request2.setValue("Bearer token-2", forHTTPHeaderField: "Authorization")

        XCTAssertEqual(KVCacheKey.make(for: request1), KVCacheKey.make(for: request2))
    }

    func testCacheKeyDiffersByMethodURLAndBody() {
        let url = URL(string: "https://example.com/a")!
        var get = URLRequest(url: url)
        get.httpMethod = "GET"

        var post = URLRequest(url: url)
        post.httpMethod = "POST"

        var postWithBody = post
        postWithBody.httpBody = Data("x".utf8)

        XCTAssertNotEqual(KVCacheKey.make(for: get), KVCacheKey.make(for: post))
        XCTAssertNotEqual(KVCacheKey.make(for: post), KVCacheKey.make(for: postWithBody))
    }
}
