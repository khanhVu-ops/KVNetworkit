//
//  KVNetworkSessionTests.swift
//  KVNetworkitTests
//

import XCTest
@testable import KVNetworkit

private struct UploadEndpoint: KVAPIEndpointProtocol {
    var method: KVHTTPMethod = .post
    var path: String = "/upload"
    var baseURL: String = "https://api.example.com"
    var body: KVHTTPBody? = .json(Data("{}".utf8))
}

/// Reports when the `URLSession` it is attached to has been invalidated.
private final class InvalidationObservingDelegate: NSObject, KVUploadProgressDelegateProtocol, @unchecked Sendable {
    let invalidated: XCTestExpectation

    init(invalidated: XCTestExpectation) {
        self.invalidated = invalidated
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        invalidated.fulfill()
    }
}

final class KVNetworkSessionTests: XCTestCase {

    func testStreamsOutliveTheRegularResourceTimeout() {
        let session = KVNetworkSession(requestTimeout: 45, resourceTimeout: 300)

        XCTAssertEqual(session.session.configuration.timeoutIntervalForResource, 300)
        XCTAssertEqual(session.streamSession.configuration.timeoutIntervalForResource, 7 * 24 * 60 * 60)
        // The idle timeout still applies to streams.
        XCTAssertEqual(session.streamSession.configuration.timeoutIntervalForRequest, 45)
        XCTAssertTrue(session.streamSession === session.streamSession, "Built once, then reused")
    }

    func testStreamResourceTimeoutIsConfigurable() {
        let session = KVNetworkSession(streamResourceTimeout: 1_800)
        XCTAssertEqual(session.streamSession.configuration.timeoutIntervalForResource, 1_800)
    }

    func testWrappedSessionIsUsedForStreams() {
        let urlSession = URLSession(configuration: .ephemeral)
        let session = KVNetworkSession(session: urlSession)
        XCTAssertTrue(session.streamSession === urlSession)
        urlSession.invalidateAndCancel()
    }

    func testPerUploadSessionIsInvalidatedAfterTheUpload() async throws {
        let invalidated = expectation(description: "upload URLSession invalidated")
        let delegate = InvalidationObservingDelegate(invalidated: invalidated)
        let client = KVAPIClient(
            interceptors: [],
            uploadSessionFactory: { delegate in
                KVNetworkSession(delegate: delegate, configuration: KVOKURLProtocol.configuration())
            }
        )

        let data = try await client.request(UploadEndpoint(), progressDelegate: delegate)
        XCTAssertEqual(data, Data("{}".utf8))

        // Without invalidation the URLSession — and the delegate it retains — would live forever.
        await fulfillment(of: [invalidated], timeout: 2)
    }
}
