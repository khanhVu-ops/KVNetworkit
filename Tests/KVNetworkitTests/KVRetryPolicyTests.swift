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
