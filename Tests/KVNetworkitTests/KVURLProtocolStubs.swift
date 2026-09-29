//
//  KVURLProtocolStubs.swift
//  KVNetworkitTests
//

import Foundation
import KVNetworkit

/// Thread-safe start/stop counters for the URL protocol stubs.
final class KVURLProtocolLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = 0
    private var _stopped = 0

    var started: Int {
        lock.lock()
        defer { lock.unlock() }
        return _started
    }

    var stopped: Int {
        lock.lock()
        defer { lock.unlock() }
        return _stopped
    }

    func recordStart() {
        lock.lock()
        _started += 1
        lock.unlock()
    }

    func recordStop() {
        lock.lock()
        _stopped += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        _started = 0
        _stopped = 0
        lock.unlock()
    }
}

/// Never answers: the request stays in flight until the `URLSession` task is canceled,
/// which is observable through `stopLoading`.
final class KVHangingURLProtocol: URLProtocol {
    static let log = KVURLProtocolLog()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.log.recordStart()
    }

    override func stopLoading() {
        Self.log.recordStop()
    }

    /// A real `KVNetworkSession` whose requests hang.
    static func makeSession() -> KVNetworkSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KVHangingURLProtocol.self]
        return KVNetworkSession(configuration: configuration)
    }
}

/// Answers every request with an empty `200`.
final class KVOKURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KVOKURLProtocol.self]
        return configuration
    }
}

/// Polls `condition` until it holds or `timeout` elapses.
func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}
