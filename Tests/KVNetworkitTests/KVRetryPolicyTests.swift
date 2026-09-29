//
//  KVRetryPolicyTests.swift
//  KVNetworkitTests
//

import XCTest
@testable import KVNetworkit

final class KVRetryPolicyTests: XCTestCase {

    func testNeverPolicyRetriesNothing() {
        let policy = KVRetryPolicy.never
        XCTAssertFalse(policy.shouldRetry(statusCode: 503))
        XCTAssertFalse(policy.shouldRetry(error: URLError(.timedOut)))
    }

    func testRetryableStatusCodes() {
        let policy = KVRetryPolicy.default
        XCTAssertTrue(policy.shouldRetry(statusCode: 503))
        XCTAssertTrue(policy.shouldRetry(statusCode: 429))
        XCTAssertFalse(policy.shouldRetry(statusCode: 404))
        XCTAssertFalse(policy.shouldRetry(statusCode: 401))
    }

    func testRetryableErrors() {
        let policy = KVRetryPolicy.default
        XCTAssertTrue(policy.shouldRetry(error: URLError(.timedOut)))
        XCTAssertTrue(policy.shouldRetry(error: KVAPIClientError.timeout))
        XCTAssertTrue(policy.shouldRetry(error: KVAPIClientError.networkError(URLError(.notConnectedToInternet))))
        XCTAssertFalse(policy.shouldRetry(error: KVAPIClientError.statusCode(404)))
        XCTAssertFalse(policy.shouldRetry(error: CancellationError()))
    }

    func testOnlyIdempotentMethodsAreRetriedByDefault() {
        let policy = KVRetryPolicy.default
        for method in ["GET", "HEAD", "PUT", "DELETE", "OPTIONS", "get", nil] {
            XCTAssertTrue(policy.shouldRetry(method: method), "\(method ?? "nil") should be retryable")
        }
        XCTAssertFalse(policy.shouldRetry(method: "POST"))
        XCTAssertFalse(policy.shouldRetry(method: "PATCH"))
    }

    func testMethodsCanBeOptedIn() {
        let policy = KVRetryPolicy(maxRetries: 1, retryableMethods: [.post])
        XCTAssertTrue(policy.shouldRetry(method: "POST"))
        XCTAssertFalse(policy.shouldRetry(method: "GET"))
    }

    func testRetryAfterSecondsIsHonouredAndCapped() {
        let policy = KVRetryPolicy(maxRetries: 2, baseDelay: 1, maxDelay: 30)
        XCTAssertEqual(policy.delay(forAttempt: 1, retryAfter: "5"), 5)
        XCTAssertEqual(policy.delay(forAttempt: 1, retryAfter: " 0 "), 0)
        XCTAssertEqual(policy.delay(forAttempt: 1, retryAfter: "3600"), 30, "Capped at maxDelay")

        // Unparsable or missing: exponential backoff (~1s ±20%).
        XCTAssertTrue((0.8...1.2).contains(policy.delay(forAttempt: 1, retryAfter: "soon")))
        XCTAssertTrue((0.8...1.2).contains(policy.delay(forAttempt: 1, retryAfter: nil)))
    }

    func testRetryAfterHTTPDateIsParsed() {
        let now = Date(timeIntervalSince1970: 1_445_412_470)   // 21 Oct 2015 07:27:50 GMT
        let seconds = KVRetryPolicy.parseRetryAfter("Wed, 21 Oct 2015 07:28:00 GMT", now: now)
        XCTAssertEqual(seconds ?? -1, 10, accuracy: 0.001)
    }

    func testBackoffGrowsExponentiallyAndIsCapped() {
        let policy = KVRetryPolicy(maxRetries: 10, baseDelay: 1.0, maxDelay: 5.0)

        // Jitter is ±20%, so compare against bounds.
        let first = policy.delay(forAttempt: 1)   // ~1s
        let second = policy.delay(forAttempt: 2)  // ~2s
        let huge = policy.delay(forAttempt: 10)   // capped at ~5s

        XCTAssertTrue((0.8...1.2).contains(first), "first delay was \(first)")
        XCTAssertTrue((1.6...2.4).contains(second), "second delay was \(second)")
        XCTAssertLessThanOrEqual(huge, 6.0)
    }
}
