//
//  KVStreamInterceptorTests.swift
//  KVNetworkitTests
//

import XCTest
@testable import KVNetworkit

private struct SpyEndpoint: KVAPIEndpointProtocol {
    var method: KVHTTPMethod = .get
    var path: String = "/chat/stream"
    var baseURL: String = "https://api.example.com"
}

private let spyURL = URL(string: "https://api.example.com/chat/stream")!

private func ok() -> HTTPURLResponse {
    KVMockNetworkSession.httpResponse(url: spyURL, statusCode: 200, headers: ["X-Model": "opus"])
}

/// Records every stream callback, and optionally transforms or fails chunks.
private final class RecordingStreamInterceptor: KVStreamInterceptorProtocol, @unchecked Sendable {

    private let lock = NSLock()
    private(set) var openedIds: [String] = []
    private(set) var openedStatusCodes: [Int] = []
    private(set) var chunks: [String] = []
    private(set) var closedIds: [String] = []
    private(set) var statistics: [KVStreamStatistics] = []
    private(set) var closeErrors: [(any Error)?] = []

    /// Applied to every chunk when set; `nil` leaves chunks untouched.
    var transform: (@Sendable (Data) -> Data)?
    /// Thrown from the chunk hook when set.
    var chunkError: (any Error)?

    func streamDidOpen(id: String, response: URLResponse) async {
        recordOpen(id: id, response: response)
    }

    func stream(id: String, didReceive chunk: Data) async throws -> Data? {
        let (transform, error) = recordChunk(chunk)
        if let error { throw error }
        return transform.map { $0(chunk) }
    }

    func streamDidClose(id: String, statistics stats: KVStreamStatistics, error: (any Error)?) async {
        recordClose(id: id, statistics: stats, error: error)
    }

    // Locking stays in synchronous methods: `NSLock.lock()` is unavailable from an
    // async context (an error in the Swift 6 language mode).

    private func recordOpen(id: String, response: URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        openedIds.append(id)
        openedStatusCodes.append((response as? HTTPURLResponse)?.statusCode ?? -1)
    }

    private func recordChunk(_ chunk: Data) -> ((@Sendable (Data) -> Data)?, (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        chunks.append(String(decoding: chunk, as: UTF8.self))
        return (transform, chunkError)
    }

    private func recordClose(id: String, statistics stats: KVStreamStatistics, error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        closedIds.append(id)
        statistics.append(stats)
        closeErrors.append(error)
    }
}

/// Emits chunks slowly so a stream can be cancelled while still open.
private final class SlowSession: KVNetworkSessionProtocol, @unchecked Sendable {

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.unsupportedURL)
    }

    func bytes(for request: URLRequest) async throws -> (KVDataStream, URLResponse) {
        let stream = KVDataStream(bufferingPolicy: .unbounded) { continuation in
            let producer = Task {
                for index in 0..<50 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                    continuation.yield(Data("data: \(index)\n\n".utf8))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
        return (stream, ok())
    }
}

final class KVStreamInterceptorTests: XCTestCase {

    private func drain(_ stream: KVDataStream) async throws -> [String] {
        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(String(decoding: chunk, as: UTF8.self))
        }
        return chunks
    }

    // MARK: - Callbacks

    func testReceivesOpenChunksAndCloseInOrder() async throws {
        let spy = RecordingStreamInterceptor()
        let session = KVMockNetworkSession()
        session.enqueueStream(
            chunks: [Data("a".utf8), Data("bb".utf8), Data("ccc".utf8)],
            response: ok()
        )
        let client = KVAPIClient(session: session, interceptors: [spy])

        _ = try await drain(try await client.stream(SpyEndpoint(), id: "chat-1"))

        XCTAssertEqual(spy.openedIds, ["chat-1"])
        XCTAssertEqual(spy.openedStatusCodes, [200])
        XCTAssertEqual(spy.chunks, ["a", "bb", "ccc"])
        XCTAssertEqual(spy.closedIds, ["chat-1"])
        XCTAssertEqual(spy.statistics.first?.chunkCount, 3)
        XCTAssertEqual(spy.statistics.first?.byteCount, 6)
        XCTAssertNil(spy.closeErrors.first ?? nil)
    }

    func testOpenIsReportedBeforeAnyChunkIsConsumed() async throws {
        let spy = RecordingStreamInterceptor()
        let session = KVMockNetworkSession()
        session.enqueueStream(chunks: [Data("a".utf8)], response: ok())
        let client = KVAPIClient(session: session, interceptors: [spy])

        let stream = try await client.stream(SpyEndpoint(), id: "chat-1")

        XCTAssertEqual(spy.openedIds, ["chat-1"], "streamDidOpen should fire when the head is validated")
        _ = try await drain(stream)
    }

    func testStatisticsCountBytesActuallyDelivered() async throws {
        let spy = RecordingStreamInterceptor()
        spy.transform = { _ in Data("XY".utf8) }   // 2 bytes out, whatever came in
        let session = KVMockNetworkSession()
        session.enqueueStream(chunks: [Data("aaaa".utf8), Data("bbbb".utf8)], response: ok())
        let client = KVAPIClient(session: session, interceptors: [spy])

        _ = try await drain(try await client.stream(SpyEndpoint(), id: "chat-1"))

        XCTAssertEqual(spy.statistics.first?.byteCount, 4, "Should count post-transform bytes")
    }

    func testNothingIsReportedWhenTheStreamFailsToOpen() async {
        let spy = RecordingStreamInterceptor()
        let session = KVMockNetworkSession()
        session.enqueueStream(
            chunks: [Data(#"{"message":"nope"}"#.utf8)],
            response: KVMockNetworkSession.httpResponse(url: spyURL, statusCode: 403)
        )
        let client = KVAPIClient(session: session, interceptors: [spy])

        _ = try? await client.stream(SpyEndpoint(), id: "chat-1")

        XCTAssertTrue(spy.openedIds.isEmpty)
        XCTAssertTrue(spy.closedIds.isEmpty)
    }

    // MARK: - Transformation

    func testChunkTransformReachesTheConsumer() async throws {
        let spy = RecordingStreamInterceptor()
        spy.transform = { Data(String(decoding: $0, as: UTF8.self).uppercased().utf8) }
        let session = KVMockNetworkSession()
        session.enqueueStream(chunks: [Data("one".utf8), Data("two".utf8)], response: ok())
        let client = KVAPIClient(session: session, interceptors: [spy])

        let received = try await drain(try await client.stream(SpyEndpoint(), id: "chat-1"))

        XCTAssertEqual(received, ["ONE", "TWO"])
    }

    func testInterceptorsAreAppliedInOrder() async throws {
        struct Appending: KVStreamInterceptorProtocol {
            let suffix: String
            func stream(id: String, didReceive chunk: Data) async throws -> Data? {
                var chunk = chunk
                chunk.append(Data(suffix.utf8))
                return chunk
            }
        }

        let session = KVMockNetworkSession()
        session.enqueueStream(chunks: [Data("x".utf8)], response: ok())
        let client = KVAPIClient(
            session: session,
            interceptors: [Appending(suffix: "-1"), Appending(suffix: "-2")]
        )

        let received = try await drain(try await client.stream(SpyEndpoint(), id: "chat-1"))

        XCTAssertEqual(received, ["x-1-2"])
    }

    // MARK: - Failures

    func testThrowingFromTheChunkHookFailsTheStream() async throws {
        struct Boom: Error {}

        let spy = RecordingStreamInterceptor()
        spy.chunkError = Boom()
        let session = KVMockNetworkSession()
        session.enqueueStream(chunks: [Data("a".utf8)], response: ok())
        let client = KVAPIClient(session: session, interceptors: [spy])

        do {
            _ = try await drain(try await client.stream(SpyEndpoint(), id: "chat-1"))
            XCTFail("Expected the stream to fail")
        } catch {
            guard case let KVAPIClientError.requestFailed(underlying) = error else {
                return XCTFail("Expected requestFailed, got \(error)")
            }
            XCTAssertTrue(underlying is Boom)
        }

        XCTAssertNotNil(spy.closeErrors.first ?? nil, "Close should report the failure")
    }

    func testCloseReportsMidStreamTransportFailure() async throws {
        let spy = RecordingStreamInterceptor()
        let session = KVMockNetworkSession()
        session.enqueueStream(
            chunks: [Data("a".utf8)],
            response: ok(),
            terminatingError: URLError(.networkConnectionLost)
        )
        let client = KVAPIClient(session: session, interceptors: [spy])

        _ = try? await drain(try await client.stream(SpyEndpoint(), id: "chat-1"))

        guard case let KVAPIClientError.networkError(urlError)? = spy.closeErrors.first as? KVAPIClientError else {
            return XCTFail("Expected networkError, got \(String(describing: spy.closeErrors.first))")
        }
        XCTAssertEqual(urlError.code, .networkConnectionLost)
        XCTAssertEqual(spy.statistics.first?.chunkCount, 1)
    }

    func testCloseReportsCancellation() async throws {
        let spy = RecordingStreamInterceptor()
        let client = KVAPIClient(session: SlowSession(), interceptors: [spy])
        let stream = try await client.stream(SpyEndpoint(), id: "chat-1")

        var count = 0
        do {
            for try await _ in stream {
                count += 1
                if count == 2 { client.cancelRequest(with: "chat-1") }
            }
        } catch {
            // Expected — the stream ends with a cancellation error.
        }

        XCTAssertEqual(spy.closedIds, ["chat-1"])
        guard case KVAPIClientError.taskCanceled? = spy.closeErrors.first as? KVAPIClientError else {
            return XCTFail("Expected taskCanceled, got \(String(describing: spy.closeErrors.first))")
        }
    }

    // MARK: - Concurrent streams

    func testConcurrentStreamsAreKeyedByRequestId() async throws {
        let spy = RecordingStreamInterceptor()
        let session = KVMockNetworkSession()
        session.enqueueStream(chunks: [Data("a".utf8)], response: ok())
        let client = KVAPIClient(session: session, interceptors: [spy])

        _ = try await drain(try await client.stream(SpyEndpoint(), id: "first"))
        _ = try await drain(try await client.stream(SpyEndpoint(), id: "second"))

        XCTAssertEqual(spy.openedIds, ["first", "second"])
        XCTAssertEqual(spy.closedIds, ["first", "second"])
    }
}

// MARK: - Logging interceptor

final class KVStreamLoggingTests: XCTestCase {

    /// Thread-safe log sink.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        var joined: String {
            lock.lock()
            defer { lock.unlock() }
            return lines.joined(separator: "\n")
        }

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }
    }

    private func runStream(
        _ interceptor: KVLoggingInterceptor,
        chunks: [Data] = [Data("data: one\n\n".utf8), Data("data: two\n\n".utf8)]
    ) async throws {
        let session = KVMockNetworkSession()
        session.enqueueStream(chunks: chunks, response: ok())
        let client = KVAPIClient(session: session, interceptors: [interceptor])

        for try await _ in try await client.stream(SpyEndpoint(), id: "chat-1") {}
    }

    func testAggregatedLoggingPrintsTheWholeBodyOnce() async throws {
        let sink = Sink()
        try await runStream(
            KVLoggingInterceptor(level: .body, streamBodyLogging: .aggregated, output: { sink.append($0) })
        )
        let log = sink.joined

        XCTAssertTrue(log.contains("STREAM OPEN [200]"))
        XCTAssertTrue(log.contains("STREAM CLOSED [2 chunks · 22 B"))
        XCTAssertTrue(log.contains("data: one"))
        XCTAssertTrue(log.contains("data: two"))
        XCTAssertFalse(log.contains("📡 chunk"), "Aggregated mode should not log per chunk")
    }

    func testPerChunkLoggingPrintsEachChunk() async throws {
        let sink = Sink()
        try await runStream(
            KVLoggingInterceptor(level: .body, streamBodyLogging: .perChunk, output: { sink.append($0) })
        )
        let log = sink.joined

        XCTAssertEqual(log.components(separatedBy: "📡 chunk").count - 1, 2)
        XCTAssertTrue(log.contains("STREAM CLOSED"))
    }

    func testNoneLoggingKeepsBodyOutOfTheLog() async throws {
        let sink = Sink()
        try await runStream(
            KVLoggingInterceptor(level: .body, streamBodyLogging: .none, output: { sink.append($0) })
        )
        let log = sink.joined

        XCTAssertTrue(log.contains("STREAM OPEN [200]"))
        XCTAssertTrue(log.contains("STREAM CLOSED"))
        XCTAssertFalse(log.contains("data: one"))
    }

    func testBasicLevelLogsNoBodyEvenWhenAggregated() async throws {
        let sink = Sink()
        try await runStream(
            KVLoggingInterceptor(level: .basic, streamBodyLogging: .aggregated, output: { sink.append($0) })
        )
        let log = sink.joined

        XCTAssertTrue(log.contains("STREAM CLOSED"))
        XCTAssertFalse(log.contains("data: one"))
    }

    func testHeadersLevelLogsResponseHeaders() async throws {
        let sink = Sink()
        try await runStream(
            KVLoggingInterceptor(level: .headers, output: { sink.append($0) })
        )

        XCTAssertTrue(sink.joined.contains("X-Model: opus"))
    }

    func testNoneLevelLogsNothing() async throws {
        let sink = Sink()
        try await runStream(KVLoggingInterceptor(level: .none, output: { sink.append($0) }))

        XCTAssertTrue(sink.joined.isEmpty)
    }

    func testAggregatedBufferIsCappedByMaxBodyLogLength() async throws {
        let sink = Sink()
        try await runStream(
            KVLoggingInterceptor(
                level: .body,
                maxBodyLogLength: 8,
                streamBodyLogging: .aggregated,
                output: { sink.append($0) }
            ),
            chunks: [Data(String(repeating: "x", count: 100).utf8)]
        )

        XCTAssertFalse(sink.joined.contains(String(repeating: "x", count: 9)))
    }

    func testFailedStreamIsLoggedWithItsError() async throws {
        let sink = Sink()
        let session = KVMockNetworkSession()
        session.enqueueStream(
            chunks: [Data("data: one\n\n".utf8)],
            response: ok(),
            terminatingError: URLError(.networkConnectionLost)
        )
        let client = KVAPIClient(
            session: session,
            interceptors: [KVLoggingInterceptor(level: .body, output: { sink.append($0) })]
        )

        do {
            for try await _ in try await client.stream(SpyEndpoint(), id: "chat-1") {}
        } catch {
            // Expected.
        }

        let log = sink.joined
        XCTAssertTrue(log.contains("❌ ━━━━━━━━━━ STREAM CLOSED"))
        XCTAssertTrue(log.contains("Error: "))
    }

    func testBuffersAreReleasedAfterEachStream() async throws {
        let interceptor = KVLoggingInterceptor(level: .body, output: { _ in })
        try await runStream(interceptor)

        XCTAssertNil(interceptor.streamBuffers.take("chat-1"), "Close should drain the buffer")
    }
}
