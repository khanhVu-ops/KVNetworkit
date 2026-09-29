//
//  KVCancellationTests.swift
//  KVNetworkitTests
//

import XCTest
@testable import KVNetworkit

private struct TestEndpoint: KVAPIEndpointProtocol {
    var method: KVHTTPMethod = .get
    var path: String = "/slow"
    var baseURL: String = "https://api.example.com"
}

/// Cancellation through a real `URLSession` (requests never answer, see `KVHangingURLProtocol`)
/// and the request-id bookkeeping around it.
final class KVCancellationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KVHangingURLProtocol.log.reset()
    }

    // MARK: - Caller cancellation

    func testCancellingTheCallerTaskCancelsTheRequest() async {
        let client = KVAPIClient(session: KVHangingURLProtocol.makeSession(), interceptors: [])

        let caller = Task { try await client.request(TestEndpoint(), id: "caller") as Void }
        let didStart = await waitUntil { KVHangingURLProtocol.log.started == 1 }
        XCTAssertTrue(didStart, "The request never reached the transport")

        let canceledAt = Date()
        caller.cancel()   // e.g. a SwiftUI `.task` whose view went away

        do {
            try await caller.value
            XCTFail("Expected taskCanceled")
        } catch {
            guard case KVAPIClientError.taskCanceled = error else {
                return XCTFail("Expected taskCanceled, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(canceledAt), 1, "Cancellation should be prompt")

        let didStop = await waitUntil { KVHangingURLProtocol.log.stopped == 1 }
        XCTAssertTrue(didStop, "The URLSession task should have been canceled")
        XCTAssertEqual(client.taskManager.activeTaskCount, 0)
    }

    func testCallerAlreadyCanceledThrowsTaskCanceled() async {
        let client = KVAPIClient(session: KVHangingURLProtocol.makeSession(), interceptors: [])

        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await client.request(TestEndpoint(), id: "precanceled") as Void
        }

        do {
            try await caller.value
            XCTFail("Expected taskCanceled")
        } catch {
            guard case KVAPIClientError.taskCanceled = error else {
                return XCTFail("Expected taskCanceled, got \(error)")
            }
        }
    }

    func testCancelRequestByIdCancelsTheURLSessionTask() async {
        let client = KVAPIClient(session: KVHangingURLProtocol.makeSession(), interceptors: [])

        let caller = Task { try await client.request(TestEndpoint(), id: "by-id") as Void }
        _ = await waitUntil { KVHangingURLProtocol.log.started == 1 }
        client.cancelRequest(with: "by-id")

        do {
            try await caller.value
            XCTFail("Expected taskCanceled")
        } catch {
            // Used to surface as `.networkError(URLError(.cancelled))` on a real URLSession.
            guard case KVAPIClientError.taskCanceled = error else {
                return XCTFail("Expected taskCanceled, got \(error)")
            }
        }
        let didStop = await waitUntil { KVHangingURLProtocol.log.stopped == 1 }
        XCTAssertTrue(didStop)
    }

    func testCancellingTheCallerWhileAStreamConnectsThrowsTaskCanceled() async {
        let client = KVAPIClient(session: KVHangingURLProtocol.makeSession(), interceptors: [])

        let caller = Task { _ = try await client.stream(TestEndpoint(), accept: nil, id: "stream") }
        _ = await waitUntil { KVHangingURLProtocol.log.started == 1 }
        caller.cancel()

        do {
            try await caller.value
            XCTFail("Expected taskCanceled")
        } catch {
            guard case KVAPIClientError.taskCanceled = error else {
                return XCTFail("Expected taskCanceled, got \(error)")
            }
        }
        let didStop = await waitUntil { KVHangingURLProtocol.log.stopped == 1 }
        XCTAssertTrue(didStop)
        let didRelease = await waitUntil { client.taskManager.activeTaskCount == 0 }
        XCTAssertTrue(didRelease)
    }

    func testCancelRequestByIdWorksWhileAStreamIsConnecting() async {
        let client = KVAPIClient(session: KVHangingURLProtocol.makeSession(), interceptors: [])

        let caller = Task { _ = try await client.stream(TestEndpoint(), accept: nil, id: "connecting") }
        _ = await waitUntil { KVHangingURLProtocol.log.started == 1 }
        client.cancelRequest(with: "connecting")

        do {
            try await caller.value
            XCTFail("Expected taskCanceled")
        } catch {
            guard case KVAPIClientError.taskCanceled = error else {
                return XCTFail("Expected taskCanceled, got \(error)")
            }
        }
    }

    // MARK: - Request-id reuse

    func testFinishingRequestDoesNotUntrackANewerRequestWithTheSameId() async throws {
        let calls = KVCallCounter()
        let session = KVMockNetworkSession()
        session.handler = { _ in
            if calls.next() == 1 {
                // The first request ignores cancellation for a while, so it finishes only
                // after the second one has claimed the id.
                Thread.sleep(forTimeInterval: 0.3)
                throw URLError(.cancelled)
            }
            let deadline = Date().addingTimeInterval(3)
            while !Task.isCancelled, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw CancellationError()
        }
        let client = KVAPIClient(session: session, interceptors: [])

        let first = Task { try await client.request(TestEndpoint(), id: "reused") as Void }
        _ = await waitUntil { calls.count == 1 }
        client.cancelRequest(with: "reused")

        let second = Task { try await client.request(TestEndpoint(), id: "reused") as Void }
        _ = await waitUntil { calls.count == 2 }

        _ = try? await first.value

        // The first request's cleanup must leave the second one tracked — and cancellable.
        XCTAssertEqual(client.taskManager.status(for: "reused"), .inProgress)
        client.cancelRequest(with: "reused")

        let canceledAt = Date()
        do {
            try await second.value
            XCTFail("Expected taskCanceled")
        } catch {
            guard case KVAPIClientError.taskCanceled = error else {
                return XCTFail("Expected taskCanceled, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(canceledAt), 1)
    }

    func testConcurrentRequestsWithTheSameIdStartOnlyOnce() async {
        let session = KVMockNetworkSession()
        session.handler = { _ in
            Thread.sleep(forTimeInterval: 0.1)
            return (Data("{}".utf8), KVMockNetworkSession.httpResponse(url: URL(string: "https://api.example.com/slow")!, statusCode: 200))
        }
        let client = KVAPIClient(session: session, interceptors: [])

        let outcomes = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for _ in 0..<20 {
                group.addTask {
                    do {
                        try await client.request(TestEndpoint(), id: "same")
                        return true
                    } catch {
                        return false
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(outcomes.filter { $0 }.count, 1, "Exactly one request may claim the id")
        XCTAssertEqual(session.receivedRequests.count, 1)
    }
}

/// Counts handler invocations from `@Sendable` closures.
private final class KVCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    /// Increments and returns the new count.
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _count += 1
        return _count
    }
}
