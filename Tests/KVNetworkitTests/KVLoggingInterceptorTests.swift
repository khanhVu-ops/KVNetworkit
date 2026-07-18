//
//  KVLoggingInterceptorTests.swift
//  KVNetworkitTests
//

import XCTest
@testable import KVNetworkit

final class KVLoggingInterceptorTests: XCTestCase {

    /// Captures interceptor output for assertions.
    private final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return _lines.joined(separator: "\n")
        }

        func append(_ line: String) {
            lock.lock()
            _lines.append(line)
            lock.unlock()
        }
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.example.com/users?page=1")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer super-secret-token-value", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"name": "Khanh"}"#.utf8)
        return request
    }

    func testCURLContainsMethodURLHeadersAndBody() async throws {
        let sink = LogSink()
        let interceptor = KVLoggingInterceptor(output: { sink.append($0) })

        _ = try await interceptor.intercept(request: makeRequest())

        let log = sink.text
        XCTAssertTrue(log.contains("curl -v"))
        XCTAssertTrue(log.contains("-X POST"))
        XCTAssertTrue(log.contains("https://api.example.com/users?page=1"))
        XCTAssertTrue(log.contains("Content-Type: application/json"))
        XCTAssertTrue(log.contains(#"-d "{\"name\": \"Khanh\"}""#))
    }

    func testSensitiveHeadersAreRedactedByDefault() async throws {
        let sink = LogSink()
        let interceptor = KVLoggingInterceptor(output: { sink.append($0) })

        _ = try await interceptor.intercept(request: makeRequest())

        XCTAssertFalse(sink.text.contains("super-secret-token-value"))
        XCTAssertTrue(sink.text.contains("Bearer super••••••"))
    }

    func testRedactionCanBeDisabled() async throws {
        let sink = LogSink()
        let interceptor = KVLoggingInterceptor(
            redactsSensitiveHeaders: false,
            output: { sink.append($0) }
        )

        _ = try await interceptor.intercept(request: makeRequest())
        XCTAssertTrue(sink.text.contains("super-secret-token-value"))
    }

    func testResponseIsPrettyPrintedWithStatus() async throws {
        let sink = LogSink()
        let interceptor = KVLoggingInterceptor(output: { sink.append($0) })

        let url = URL(string: "https://api.example.com/users")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        let body = Data(#"{"id":"1","name":"Khanh"}"#.utf8)

        _ = try await interceptor.intercept(response: response, data: body)

        let log = sink.text
        XCTAssertTrue(log.contains("RESPONSE [200]"))
        XCTAssertTrue(log.contains("✅"))
        XCTAssertTrue(log.contains("\"name\" : \"Khanh\""))
    }

    func testErrorResponseUsesFailureMarker() async throws {
        let sink = LogSink()
        let interceptor = KVLoggingInterceptor(output: { sink.append($0) })

        let url = URL(string: "https://api.example.com/users")!
        let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)

        _ = try await interceptor.intercept(response: response, data: Data())
        XCTAssertTrue(sink.text.contains("❌"))
        XCTAssertTrue(sink.text.contains("RESPONSE [404]"))
    }

    func testLevelNoneLogsNothing() async throws {
        let sink = LogSink()
        let interceptor = KVLoggingInterceptor(level: .none, output: { sink.append($0) })

        _ = try await interceptor.intercept(request: makeRequest())
        _ = try await interceptor.intercept(response: nil, data: nil)
        XCTAssertTrue(sink.text.isEmpty)
    }

    func testBasicLevelOmitsBody() async throws {
        let sink = LogSink()
        let interceptor = KVLoggingInterceptor(level: .basic, output: { sink.append($0) })

        _ = try await interceptor.intercept(request: makeRequest())
        let log = sink.text
        XCTAssertTrue(log.contains("POST https://api.example.com/users?page=1"))
        XCTAssertFalse(log.contains("curl"))
        XCTAssertFalse(log.contains("Khanh"))
    }

    func testLongBodiesAreTruncated() async throws {
        let sink = LogSink()
        let interceptor = KVLoggingInterceptor(maxBodyLogLength: 50, output: { sink.append($0) })

        let url = URL(string: "https://api.example.com/big")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        let longText = String(repeating: "a", count: 500)

        _ = try await interceptor.intercept(response: response, data: Data(longText.utf8))
        XCTAssertTrue(sink.text.contains("truncated"))
        XCTAssertFalse(sink.text.contains(longText))
    }
}
