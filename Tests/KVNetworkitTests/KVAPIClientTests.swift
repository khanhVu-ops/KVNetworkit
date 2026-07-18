//
//  KVAPIClientTests.swift
//  KVNetworkitTests
//

import XCTest
@testable import KVNetworkit

private struct User: Codable, Equatable {
    let id: String
    let name: String
}

private struct TestEndpoint: KVAPIEndpointProtocol {
    var method: KVHTTPMethod = .get
    var path: String = "/users/me"
    var baseURL: String = "https://api.example.com"
    var body: KVHTTPBody?
    var cachePolicy: KVCachePolicy = .ignore
}

private let testURL = URL(string: "https://api.example.com/users/me")!

final class KVAPIClientTests: XCTestCase {

    private func userData() -> Data {
        try! JSONEncoder().encode(User(id: "1", name: "Khanh"))
    }

    // MARK: - Happy path

    func testRequestDecodesResponse() async throws {
        let session = KVMockNetworkSession()
        session.enqueue(.success((userData(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 200))))
        let client = KVAPIClient(session: session, interceptors: [])

        let user: User = try await client.request(TestEndpoint())
        XCTAssertEqual(user, User(id: "1", name: "Khanh"))
        XCTAssertEqual(session.receivedRequests.count, 1)
    }

    func testDecodingFailureThrowsDecodingFailed() async {
        let session = KVMockNetworkSession()
        session.enqueue(.success((Data("not json".utf8), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 200))))
        let client = KVAPIClient(session: session, interceptors: [])

        do {
            let _: User = try await client.request(TestEndpoint())
            XCTFail("Expected decodingFailed")
        } catch {
            guard case KVAPIClientError.decodingFailed = error else {
                return XCTFail("Expected decodingFailed, got \(error)")
            }
        }
    }

    // MARK: - Error mapping

    func testServerErrorMessageIsExtracted() async {
        let session = KVMockNetworkSession()
        let errorBody = Data(#"{"message": "Email already taken"}"#.utf8)
        session.enqueue(.success((errorBody, KVMockNetworkSession.httpResponse(url: testURL, statusCode: 422))))
        let client = KVAPIClient(session: session, interceptors: [])

        do {
            try await client.request(TestEndpoint())
            XCTFail("Expected serverMessage")
        } catch {
            guard case let KVAPIClientError.serverMessage(message, statusCode) = error else {
                return XCTFail("Expected serverMessage, got \(error)")
            }
            XCTAssertEqual(message, "Email already taken")
            XCTAssertEqual(statusCode, 422)
        }
    }

    func testNestedServerErrorMessageIsExtracted() {
        let nested = Data(#"{"error": {"message": "Invalid token"}}"#.utf8)
        XCTAssertEqual(KVServerErrorMessage.extract(from: nested), "Invalid token")

        let flat = Data(#"{"error": "Plain error"}"#.utf8)
        XCTAssertEqual(KVServerErrorMessage.extract(from: flat), "Plain error")

        let list = Data(#"{"errors": ["First", "Second"]}"#.utf8)
        XCTAssertEqual(KVServerErrorMessage.extract(from: list), "First")
    }

    func testStatusCodeErrorWhenBodyHasNoMessage() async {
        let session = KVMockNetworkSession()
        session.enqueue(.success((Data(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 500))))
        let client = KVAPIClient(session: session, interceptors: [])

        do {
            try await client.request(TestEndpoint())
            XCTFail("Expected statusCode error")
        } catch {
            guard case KVAPIClientError.statusCode(500) = error else {
                return XCTFail("Expected statusCode(500), got \(error)")
            }
        }
    }

    func testTimeoutURLErrorIsMappedToTimeout() async {
        let session = KVMockNetworkSession()
        session.enqueue(.failure(URLError(.timedOut)))
        let client = KVAPIClient(session: session, interceptors: [])

        do {
            try await client.request(TestEndpoint())
            XCTFail("Expected timeout")
        } catch {
            guard case KVAPIClientError.timeout = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        }
    }

    // MARK: - Retry

    func testRetriesOnRetryableStatusThenSucceeds() async throws {
        let session = KVMockNetworkSession()
        session.enqueue(.success((Data(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 503))))
        session.enqueue(.success((userData(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 200))))
        let client = KVAPIClient(
            session: session,
            interceptors: [],
            retryPolicy: KVRetryPolicy(maxRetries: 2, baseDelay: 0.01, maxDelay: 0.05)
        )

        let user: User = try await client.request(TestEndpoint())
        XCTAssertEqual(user.id, "1")
        XCTAssertEqual(session.receivedRequests.count, 2)
    }

    func testDoesNotRetryWhenPolicyIsNever() async {
        let session = KVMockNetworkSession()
        session.enqueue(.success((Data(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 503))))
        let client = KVAPIClient(session: session, interceptors: [], retryPolicy: .never)

        _ = try? await client.request(TestEndpoint()) as Void
        XCTAssertEqual(session.receivedRequests.count, 1)
    }

    // MARK: - Cache

    func testCacheFirstServesFreshEntryWithoutNetwork() async throws {
        let session = KVMockNetworkSession()
        session.enqueue(.success((userData(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 200))))
        let cache = KVMemoryCache()
        let client = KVAPIClient(session: session, interceptors: [], cache: cache)

        var endpoint = TestEndpoint()
        endpoint.cachePolicy = .cacheFirst(ttl: 60)

        // First call hits the network and stores the response.
        let first: User = try await client.request(endpoint)
        XCTAssertEqual(session.receivedRequests.count, 1)

        // Second call must be served from cache.
        let second: User = try await client.request(endpoint)
        XCTAssertEqual(session.receivedRequests.count, 1)
        XCTAssertEqual(first, second)
    }

    func testNetworkFirstFallsBackToCacheOnConnectivityError() async throws {
        let session = KVMockNetworkSession()
        let cache = KVMemoryCache()
        let client = KVAPIClient(session: session, interceptors: [], cache: cache)

        var endpoint = TestEndpoint()
        endpoint.cachePolicy = .networkFirst(ttl: 60)

        // Seed the cache with a successful call.
        session.enqueue(.success((userData(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 200))))
        let _: User = try await client.request(endpoint)

        // Now the network dies — the cached value must be returned.
        session.handler = { _ in throw URLError(.notConnectedToInternet) }
        let fallback: User = try await client.request(endpoint)
        XCTAssertEqual(fallback, User(id: "1", name: "Khanh"))
    }

    func testNetworkFirstDoesNotSwallowServerErrors() async throws {
        let session = KVMockNetworkSession()
        let cache = KVMemoryCache()
        let client = KVAPIClient(session: session, interceptors: [], cache: cache)

        var endpoint = TestEndpoint()
        endpoint.cachePolicy = .networkFirst(ttl: 60)

        session.enqueue(.success((userData(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 200))))
        let _: User = try await client.request(endpoint)

        // A real server error (404) must propagate, not fall back to cache.
        session.handler = { _ in
            (Data(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 404))
        }
        do {
            let _: User = try await client.request(endpoint)
            XCTFail("Expected statusCode error")
        } catch {
            guard case KVAPIClientError.statusCode(404) = error else {
                return XCTFail("Expected statusCode(404), got \(error)")
            }
        }
    }

    func testIgnorePolicySkipsCacheEntirely() async throws {
        let session = KVMockNetworkSession()
        session.enqueue(.success((userData(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 200))))
        let cache = KVMemoryCache()
        let client = KVAPIClient(session: session, interceptors: [], cache: cache)

        let _: User = try await client.request(TestEndpoint()) // .ignore default
        let count = await cache.count
        XCTAssertEqual(count, 0)
    }

    // MARK: - Interceptors

    func testRequestInterceptorsRunInOrder() async throws {
        let session = KVMockNetworkSession()
        session.enqueue(.success((userData(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 200))))

        let first = KVMockNetworkInterceptor(requestModifier: { request in
            var request = request
            request.setValue("1", forHTTPHeaderField: "X-Order")
            return request
        })
        let second = KVMockNetworkInterceptor(requestModifier: { request in
            var request = request
            let existing = request.value(forHTTPHeaderField: "X-Order") ?? ""
            request.setValue(existing + "2", forHTTPHeaderField: "X-Order")
            return request
        })

        let client = KVAPIClient(session: session, interceptors: [first, second])
        let _: User = try await client.request(TestEndpoint())

        XCTAssertEqual(session.receivedRequests.first?.value(forHTTPHeaderField: "X-Order"), "12")
    }

    func testAuthInterceptorInjectsBearerToken() async throws {
        let session = KVMockNetworkSession()
        session.enqueue(.success((userData(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 200))))
        let client = KVAPIClient(
            session: session,
            interceptors: [KVAuthInterceptor(tokenProvider: { "abc123" })]
        )

        let _: User = try await client.request(TestEndpoint())
        XCTAssertEqual(
            session.receivedRequests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer abc123"
        )
    }

    // MARK: - Token refresh

    private struct RefreshingInterceptor: KVTokenRefreshingInterceptorProtocol {
        let onRefresh: @Sendable () -> Void

        func refreshAction(response: URLResponse?, data: Data?) async throws -> KVInterceptorAction {
            guard (response as? HTTPURLResponse)?.statusCode == 401 else { return .proceed }
            onRefresh()
            return .retryWithUpdatedToken
        }
    }

    func testTokenRefreshRetriesOriginalRequestOnce() async throws {
        let session = KVMockNetworkSession()
        session.enqueue(.success((Data(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 401))))
        session.enqueue(.success((userData(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 200))))

        let refreshCount = KVAtomicCounter()
        let client = KVAPIClient(
            session: session,
            interceptors: [RefreshingInterceptor(onRefresh: { refreshCount.increment() })]
        )

        let user: User = try await client.request(TestEndpoint())
        XCTAssertEqual(user.id, "1")
        XCTAssertEqual(refreshCount.value, 1)
        XCTAssertEqual(session.receivedRequests.count, 2)
    }

    func testTokenRefreshDoesNotLoopOnRepeated401() async {
        let session = KVMockNetworkSession()
        // Server keeps returning 401 even after refresh.
        session.handler = { _ in
            (Data(), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 401))
        }

        let refreshCount = KVAtomicCounter()
        let client = KVAPIClient(
            session: session,
            interceptors: [RefreshingInterceptor(onRefresh: { refreshCount.increment() })]
        )

        do {
            try await client.request(TestEndpoint())
            XCTFail("Expected failure")
        } catch {
            // Only ONE refresh may happen — no infinite loop.
            XCTAssertEqual(refreshCount.value, 1)
            XCTAssertEqual(session.receivedRequests.count, 2)
        }
    }

    // MARK: - Cancellation & duplicate ids

    func testCancelRequestThrowsTaskCanceled() async {
        let session = KVMockNetworkSession()
        session.handler = { _ in
            try? Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.05)
            throw CancellationError()
        }
        let client = KVAPIClient(session: session, interceptors: [])

        let id = "cancellable"
        async let result: Void = client.request(TestEndpoint(), id: id)
        try? await Task.sleep(nanoseconds: 10_000_000)
        client.cancelRequest(with: id)

        do {
            try await result
            XCTFail("Expected taskCanceled")
        } catch {
            guard case KVAPIClientError.taskCanceled = error else {
                return XCTFail("Expected taskCanceled, got \(error)")
            }
        }
    }

    func testDuplicateInFlightIdThrowsTaskInProgress() async {
        let session = KVMockNetworkSession()
        session.handler = { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return (Data("{}".utf8), KVMockNetworkSession.httpResponse(url: testURL, statusCode: 200))
        }
        let client = KVAPIClient(session: session, interceptors: [])

        let id = "duplicate"
        async let first: Void = client.request(TestEndpoint(), id: id)
        try? await Task.sleep(nanoseconds: 50_000_000)

        do {
            try await client.request(TestEndpoint(), id: id)
            XCTFail("Expected taskInProgress")
        } catch {
            guard case KVAPIClientError.taskInProgress = error else {
                return XCTFail("Expected taskInProgress, got \(error)")
            }
        }

        _ = try? await first
    }

    // MARK: - Connectivity classification

    func testConnectivityErrorClassification() {
        XCTAssertTrue(KVAPIClientError.timeout.isNetworkConnectivityError)
        XCTAssertTrue(KVAPIClientError.networkUnavailable.isNetworkConnectivityError)
        XCTAssertTrue(KVAPIClientError.networkError(URLError(.notConnectedToInternet)).isNetworkConnectivityError)
        XCTAssertFalse(KVAPIClientError.statusCode(500).isNetworkConnectivityError)
        XCTAssertFalse(KVAPIClientError.unauthorized.isNetworkConnectivityError)
    }
}

/// Tiny thread-safe counter for assertions from @Sendable closures.
private final class KVAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}
