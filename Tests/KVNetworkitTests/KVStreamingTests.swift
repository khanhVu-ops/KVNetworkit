//
//  KVStreamingTests.swift
//  KVNetworkitTests
//

import XCTest
@testable import KVNetworkit

private struct Delta: Codable, Equatable {
    let type: String
    let content: String?
}

private struct StreamEndpoint: KVAPIEndpointProtocol {
    var method: KVHTTPMethod = .post
    var path: String = "/chat/stream"
    var baseURL: String = "https://api.example.com"
    var headers: [String: String] = [:]
    var body: KVHTTPBody?
    var retryPolicy: KVRetryPolicy?
}

private let streamURL = URL(string: "https://api.example.com/chat/stream")!

private func okResponse() -> HTTPURLResponse {
    KVMockNetworkSession.httpResponse(
        url: streamURL,
        statusCode: 200,
        headers: ["Content-Type": "text/event-stream"]
    )
}

/// Emits one chunk at a time with a small delay, so a stream can be cancelled while open.
private final class SlowStreamSession: KVNetworkSessionProtocol, @unchecked Sendable {

    let chunkCount: Int

    init(chunkCount: Int = 50) {
        self.chunkCount = chunkCount
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.unsupportedURL)
    }

    func bytes(for request: URLRequest) async throws -> (KVDataStream, URLResponse) {
        let count = chunkCount
        let stream = KVDataStream(bufferingPolicy: .unbounded) { continuation in
            let producer = Task {
                for index in 0..<count {
                    try await Task.sleep(nanoseconds: 10_000_000)
                    continuation.yield(Data("data: chunk-\(index)\n\n".utf8))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
        return (stream, okResponse())
    }
}

final class KVStreamingClientTests: XCTestCase {

    // MARK: - Happy path

    func testStreamEventsYieldsEventsInOrder() async throws {
        let session = KVMockNetworkSession()
        session.enqueueStream(
            chunks: KVMockNetworkSession.sseChunks(["one", "two", "[DONE]"]),
            response: okResponse()
        )
        let client = KVAPIClient(session: session, interceptors: [])

        var received: [String] = []
        for try await event in try await client.streamEvents(StreamEndpoint()) {
            received.append(event.data)
        }

        XCTAssertEqual(received, ["one", "two", "[DONE]"])
    }

    func testStreamDecodesTypedValuesAndSkipsDoneSentinel() async throws {
        let session = KVMockNetworkSession()
        session.enqueueStream(
            chunks: KVMockNetworkSession.sseChunks([
                #"{"type":"chunk","content":"xin "}"#,
                #"{"type":"chunk","content":"chào"}"#,
                "[DONE]"
            ]),
            response: okResponse()
        )
        let client = KVAPIClient(session: session, interceptors: [])

        var text = ""
        for try await delta in try await client.stream(StreamEndpoint(), as: Delta.self) {
            text += delta.content ?? ""
        }

        XCTAssertEqual(text, "xin chào")
    }

    func testStreamReassemblesEventsSplitAcrossChunks() async throws {
        let session = KVMockNetworkSession()
        let payload = "data: {\"type\":\"chunk\",\"content\":\"hello\"}\n\ndata: [DONE]\n\n"
        session.enqueueStream(
            chunks: KVMockNetworkSession.chunks(of: payload, size: 3),
            response: okResponse()
        )
        let client = KVAPIClient(session: session, interceptors: [])

        var contents: [String] = []
        for try await delta in try await client.stream(StreamEndpoint(), as: Delta.self) {
            contents.append(delta.content ?? "")
        }

        XCTAssertEqual(contents, ["hello"])
    }

    func testStreamLinesReturnsWholeLines() async throws {
        let session = KVMockNetworkSession()
        session.enqueueStream(
            chunks: KVMockNetworkSession.chunks(of: "first\nsecond\nthird", size: 2),
            response: okResponse()
        )
        let client = KVAPIClient(session: session, interceptors: [])

        var lines: [String] = []
        for try await line in try await client.streamLines(StreamEndpoint()) {
            lines.append(line)
        }

        XCTAssertEqual(lines, ["first", "second", "third"])
    }

    func testJSONLinesFramingDecodesEachLine() async throws {
        let session = KVMockNetworkSession()
        session.enqueueStream(
            chunks: [Data("{\"type\":\"a\"}\n{\"type\":\"b\"}\n".utf8)],
            response: okResponse()
        )
        let client = KVAPIClient(session: session, interceptors: [])

        var types: [String] = []
        for try await delta in try await client.stream(
            StreamEndpoint(),
            as: Delta.self,
            framing: .jsonLines
        ) {
            types.append(delta.type)
        }

        XCTAssertEqual(types, ["a", "b"])
    }

    func testTrailingEventWithoutBlankLineIsDelivered() async throws {
        let session = KVMockNetworkSession()
        session.enqueueStream(chunks: [Data("data: only".utf8)], response: okResponse())
        let client = KVAPIClient(session: session, interceptors: [])

        var received: [String] = []
        for try await event in try await client.streamEvents(StreamEndpoint()) {
            received.append(event.data)
        }

        XCTAssertEqual(received, ["only"])
    }

    // MARK: - Headers

    func testAcceptHeaderIsAppliedForSSE() async throws {
        let session = KVMockNetworkSession()
        session.enqueueStream(chunks: [], response: okResponse())
        let client = KVAPIClient(session: session, interceptors: [])

        for try await _ in try await client.streamEvents(StreamEndpoint()) {}

        XCTAssertEqual(session.receivedRequests.first?.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testEndpointAcceptHeaderWins() async throws {
        let session = KVMockNetworkSession()
        session.enqueueStream(chunks: [], response: okResponse())
        let client = KVAPIClient(session: session, interceptors: [])
        let endpoint = StreamEndpoint(headers: ["Accept": "application/json"])

        for try await _ in try await client.streamEvents(endpoint) {}

        XCTAssertEqual(session.receivedRequests.first?.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testRequestInterceptorsRunOnStreams() async throws {
        let session = KVMockNetworkSession()
        session.enqueueStream(chunks: [], response: okResponse())
        let client = KVAPIClient(
            session: session,
            interceptors: [KVHeaderInjectorInterceptor(headers: ["X-Trace": "abc"])]
        )

        for try await _ in try await client.streamEvents(StreamEndpoint()) {}

        XCTAssertEqual(session.receivedRequests.first?.value(forHTTPHeaderField: "X-Trace"), "abc")
    }

    // MARK: - Errors

    func testNonSuccessStatusThrowsServerMessageBeforeFirstChunk() async {
        let session = KVMockNetworkSession()
        session.enqueueStream(
            chunks: [Data(#"{"message":"Quota exceeded"}"#.utf8)],
            response: KVMockNetworkSession.httpResponse(url: streamURL, statusCode: 429)
        )
        let client = KVAPIClient(session: session, interceptors: [])

        do {
            _ = try await client.streamEvents(StreamEndpoint())
            XCTFail("Expected serverMessage")
        } catch {
            guard case let KVAPIClientError.serverMessage(message, statusCode) = error else {
                return XCTFail("Expected serverMessage, got \(error)")
            }
            XCTAssertEqual(message, "Quota exceeded")
            XCTAssertEqual(statusCode, 429)
        }
    }

    func testMidStreamFailureIsSurfacedToTheConsumer() async throws {
        let session = KVMockNetworkSession()
        session.enqueueStream(
            chunks: KVMockNetworkSession.sseChunks(["one"]),
            response: okResponse(),
            terminatingError: URLError(.networkConnectionLost)
        )
        let client = KVAPIClient(session: session, interceptors: [])

        var received: [String] = []
        do {
            for try await event in try await client.streamEvents(StreamEndpoint()) {
                received.append(event.data)
            }
            XCTFail("Expected the stream to fail")
        } catch {
            guard case let KVAPIClientError.networkError(urlError) = error else {
                return XCTFail("Expected networkError, got \(error)")
            }
            XCTAssertEqual(urlError.code, .networkConnectionLost)
        }

        XCTAssertEqual(received, ["one"], "Events received before the failure should still reach the consumer")
    }

    func testUndecodablePayloadThrowsDecodingFailed() async {
        let session = KVMockNetworkSession()
        session.enqueueStream(chunks: KVMockNetworkSession.sseChunks(["not json"]), response: okResponse())
        let client = KVAPIClient(session: session, interceptors: [])

        do {
            for try await _ in try await client.stream(StreamEndpoint(), as: Delta.self) {}
            XCTFail("Expected decodingFailed")
        } catch {
            guard case KVAPIClientError.decodingFailed = error else {
                return XCTFail("Expected decodingFailed, got \(error)")
            }
        }
    }

    func testInvalidURLThrowsBeforeTouchingTheNetwork() async {
        let session = KVMockNetworkSession()
        let client = KVAPIClient(session: session, interceptors: [])
        let endpoint = StreamEndpoint(baseURL: "https://exa mple.com")

        do {
            _ = try await client.stream(endpoint)
            XCTFail("Expected invalidURL")
        } catch {
            guard case KVAPIClientError.invalidURL = error else {
                return XCTFail("Expected invalidURL, got \(error)")
            }
        }
        XCTAssertTrue(session.receivedRequests.isEmpty)
    }

    // MARK: - Retry

    func testConnectionFailureIsRetriedBeforeTheFirstChunk() async throws {
        let session = KVMockNetworkSession()
        session.enqueueStream(error: URLError(.timedOut))
        session.enqueueStream(
            chunks: KVMockNetworkSession.sseChunks(["recovered"]),
            response: okResponse()
        )
        let client = KVAPIClient(
            session: session,
            interceptors: [],
            // Streams here are POSTs, which are only retried when the policy opts them in.
            retryPolicy: KVRetryPolicy(maxRetries: 2, baseDelay: 0.01, retryableMethods: [.post])
        )

        var received: [String] = []
        for try await event in try await client.streamEvents(StreamEndpoint()) {
            received.append(event.data)
        }

        XCTAssertEqual(received, ["recovered"])
        XCTAssertEqual(session.receivedRequests.count, 2)
    }

    func testRetryableStatusIsRetriedBeforeTheFirstChunk() async throws {
        let session = KVMockNetworkSession()
        session.enqueueStream(
            chunks: [Data(#"{"message":"try later"}"#.utf8)],
            response: KVMockNetworkSession.httpResponse(url: streamURL, statusCode: 503)
        )
        session.enqueueStream(
            chunks: KVMockNetworkSession.sseChunks(["recovered"]),
            response: okResponse()
        )
        let client = KVAPIClient(session: session, interceptors: [], retryPolicy: .never)

        // The endpoint's own policy replaces the client's.
        var endpoint = StreamEndpoint()
        endpoint.retryPolicy = KVRetryPolicy(maxRetries: 1, baseDelay: 0.01, retryableMethods: [.post])

        var received: [String] = []
        for try await event in try await client.streamEvents(endpoint) {
            received.append(event.data)
        }

        XCTAssertEqual(received, ["recovered"])
        XCTAssertEqual(session.receivedRequests.count, 2)
    }

    func testPostStreamIsNotRetriedByDefault() async {
        let session = KVMockNetworkSession()
        session.enqueueStream(
            chunks: [Data(#"{"message":"try later"}"#.utf8)],
            response: KVMockNetworkSession.httpResponse(url: streamURL, statusCode: 503)
        )
        session.enqueueStream(chunks: KVMockNetworkSession.sseChunks(["recovered"]), response: okResponse())
        let client = KVAPIClient(
            session: session,
            interceptors: [],
            retryPolicy: KVRetryPolicy(maxRetries: 2, baseDelay: 0.01)
        )

        do {
            _ = try await client.streamEvents(StreamEndpoint())
            XCTFail("Expected the 503 to be surfaced")
        } catch {
            XCTAssertEqual((error as? KVAPIClientError)?.statusCode, 503)
        }
        XCTAssertEqual(session.receivedRequests.count, 1, "A POST (e.g. a chat message) must not be replayed")
    }

    func testStreamErrorResponseCanBeMapped() async {
        let session = KVMockNetworkSession()
        let body = Data(#"{"detail":"Insufficient credits","extra":{"requiredCredits":120}}"#.utf8)
        session.enqueueStream(
            chunks: [body],
            response: KVMockNetworkSession.httpResponse(url: streamURL, statusCode: 402)
        )
        let client = KVAPIClient(session: session, interceptors: [], errorResponseMapper: { $0 })

        do {
            _ = try await client.stream(StreamEndpoint(), as: Delta.self)
            XCTFail("Expected an error response")
        } catch let error as KVHTTPErrorResponse {
            XCTAssertEqual(error.statusCode, 402)
            XCTAssertEqual(error.data, body)
        } catch {
            XCTFail("Expected KVHTTPErrorResponse, got \(error)")
        }
    }

    // MARK: - Cancellation

    func testCancelRequestStopsAnOpenStream() async throws {
        let client = KVAPIClient(session: SlowStreamSession(), interceptors: [])
        let stream = try await client.streamEvents(StreamEndpoint(), id: "chat")

        var received = 0
        do {
            for try await _ in stream {
                received += 1
                if received == 2 { client.cancelRequest(with: "chat") }
            }
            XCTFail("Expected the stream to end with a cancellation error")
        } catch KVAPIClientError.taskCanceled {
            // Expected.
        } catch is CancellationError {
            // Also acceptable: the cancellation surfaced straight from the transport.
        } catch {
            XCTFail("Expected a cancellation error, got \(error)")
        }

        XCTAssertLessThan(received, 50, "Cancellation should stop the stream early")
    }

    func testDuplicateStreamIdIsRejectedWhileTheFirstIsOpen() async throws {
        let client = KVAPIClient(session: SlowStreamSession(), interceptors: [])
        let stream = try await client.stream(StreamEndpoint(), id: "chat")

        do {
            _ = try await client.stream(StreamEndpoint(), id: "chat")
            XCTFail("Expected taskInProgress")
        } catch {
            guard case KVAPIClientError.taskInProgress = error else {
                return XCTFail("Expected taskInProgress, got \(error)")
            }
        }

        client.cancelRequest(with: "chat")
        _ = stream
    }

    // MARK: - Mock client

    func testMockAPIClientServesStubbedStream() async throws {
        let mock = KVMockAPIClient()
        mock.stub(path: "/chat/stream", streamPayloads: [#"{"type":"chunk","content":"hi"}"#, "[DONE]"])

        var contents: [String] = []
        for try await delta in try await mock.stream(StreamEndpoint(), as: Delta.self) {
            contents.append(delta.content ?? "")
        }

        XCTAssertEqual(contents, ["hi"])
        XCTAssertEqual(mock.requestedPaths, ["/chat/stream"])
    }
}
