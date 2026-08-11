//
//  KVSSEParserTests.swift
//  KVNetworkitTests
//

import XCTest
@testable import KVNetworkit

final class KVLineAccumulatorTests: XCTestCase {

    func testSplitsOnAllNewlineFlavors() {
        var accumulator = KVLineAccumulator()
        let lines = accumulator.lines(from: Data("a\nb\r\nc\rd".utf8))

        XCTAssertEqual(lines, ["a", "b", "c"])
        XCTAssertEqual(accumulator.flush(), "d")
    }

    func testHoldsBackIncompleteLineUntilTerminatorArrives() {
        var accumulator = KVLineAccumulator()

        XCTAssertEqual(accumulator.lines(from: Data("hel".utf8)), [])
        XCTAssertEqual(accumulator.lines(from: Data("lo\n".utf8)), ["hello"])
    }

    func testCRLFSplitAcrossChunksIsOneTerminator() {
        var accumulator = KVLineAccumulator()

        XCTAssertEqual(accumulator.lines(from: Data("first\r".utf8)), ["first"])
        XCTAssertEqual(accumulator.lines(from: Data("\nsecond\n".utf8)), ["second"])
    }

    func testReassemblesMultiByteCharacterSplitAcrossChunks() {
        var accumulator = KVLineAccumulator()
        // "Chào" — the "à" is two UTF-8 bytes, split between the two chunks.
        let bytes = Array("Chào\n".utf8)
        let split = bytes.firstIndex(of: 0xC3)! + 1

        XCTAssertEqual(accumulator.lines(from: Data(bytes[..<split])), [])
        XCTAssertEqual(accumulator.lines(from: Data(bytes[split...])), ["Chào"])
    }

    func testStripsLeadingByteOrderMark() {
        var accumulator = KVLineAccumulator()
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("data: hi\n".utf8))

        XCTAssertEqual(accumulator.lines(from: data), ["data: hi"])
    }

    func testFlushReturnsNilWhenNothingBuffered() {
        var accumulator = KVLineAccumulator()
        _ = accumulator.lines(from: Data("done\n".utf8))

        XCTAssertNil(accumulator.flush())
    }
}

final class KVSSEParserTests: XCTestCase {

    // MARK: - Spec framing

    func testParsesSingleEvent() {
        var parser = KVSSEParser()
        let events = parser.parse(Data("data: hello\n\n".utf8))

        XCTAssertEqual(events, [KVServerSentEvent(data: "hello")])
    }

    func testJoinsMultipleDataLinesWithNewline() {
        var parser = KVSSEParser()
        let events = parser.parse(Data("data: line one\ndata: line two\n\n".utf8))

        XCTAssertEqual(events.map(\.data), ["line one\nline two"])
    }

    func testParsesEventIdAndRetryFields() {
        var parser = KVSSEParser()
        let events = parser.parse(Data("event: delta\nid: 42\nretry: 3000\ndata: hi\n\n".utf8))

        XCTAssertEqual(events, [KVServerSentEvent(event: "delta", data: "hi", id: "42", retry: 3000)])
    }

    func testEventIdPersistsAcrossEventsButEventTypeDoesNot() {
        var parser = KVSSEParser()
        var events = parser.parse(Data("id: 1\nevent: start\ndata: a\n\n".utf8))
        events += parser.parse(Data("data: b\n\n".utf8))

        XCTAssertEqual(events.map(\.id), ["1", "1"])
        XCTAssertEqual(events.map(\.event), ["start", nil])
    }

    func testIgnoresCommentsAndUnknownFields() {
        var parser = KVSSEParser()
        let events = parser.parse(Data(": keep-alive ping\nfoo: bar\ndata: payload\n\n".utf8))

        XCTAssertEqual(events.map(\.data), ["payload"])
    }

    func testBlankLineWithoutDataDispatchesNothing() {
        var parser = KVSSEParser()

        XCTAssertTrue(parser.parse(Data("event: ping\n\n".utf8)).isEmpty)
    }

    func testValueKeepsWhitespaceBeyondTheFirstSpace() {
        var parser = KVSSEParser()
        let events = parser.parse(Data("data:  leading kept\n\n".utf8))

        XCTAssertEqual(events.map(\.data), [" leading kept"])
    }

    func testDataFieldWithoutSpaceAfterColon() {
        var parser = KVSSEParser()
        let events = parser.parse(Data("data:tight\n\n".utf8))

        XCTAssertEqual(events.map(\.data), ["tight"])
    }

    func testReassemblesEventSplitByteByByte() {
        var parser = KVSSEParser()
        let payload = "event: delta\r\ndata: {\"text\":\"xin chào\"}\r\n\r\ndata: [DONE]\r\n\r\n"

        var events: [KVServerSentEvent] = []
        for chunk in KVMockNetworkSession.chunks(of: payload, size: 1) {
            events += parser.parse(chunk)
        }

        XCTAssertEqual(events.map(\.data), ["{\"text\":\"xin chào\"}", "[DONE]"])
        XCTAssertTrue(events.last?.isDoneSentinel == true)
    }

    func testFinishFlushesFrameWithoutTrailingBlankLine() {
        var parser = KVSSEParser()

        XCTAssertTrue(parser.parse(Data("data: last one".utf8)).isEmpty)
        XCTAssertEqual(parser.finish().map(\.data), ["last one"])
    }

    func testFinishIsEmptyWhenStreamEndedCleanly() {
        var parser = KVSSEParser()
        _ = parser.parse(Data("data: done\n\n".utf8))

        XCTAssertTrue(parser.finish().isEmpty)
    }

    // MARK: - Relaxed framing

    func testPerLineFramingDispatchesWithoutBlankLine() {
        var parser = KVSSEParser(framing: .serverSentEventsPerLine)
        let events = parser.parse(Data("data: one\ndata: two\ndata: three\n".utf8))

        XCTAssertEqual(events.map(\.data), ["one", "two", "three"])
    }

    func testPerLineFramingCarriesEventTypePerLine() {
        var parser = KVSSEParser(framing: .serverSentEventsPerLine)
        let events = parser.parse(Data("event: chunk\ndata: one\ndata: two\n".utf8))

        XCTAssertEqual(events.map(\.event), ["chunk", nil])
    }

    // MARK: - JSON lines

    func testJSONLinesFramingTreatsEveryLineAsPayload() {
        var parser = KVSSEParser(framing: .jsonLines)
        let events = parser.parse(Data("{\"a\":1}\n\n{\"b\":2}\n".utf8))

        XCTAssertEqual(events.map(\.data), ["{\"a\":1}", "{\"b\":2}"])
    }

    // MARK: - Decoding

    func testDecodesPayload() throws {
        struct Delta: Decodable, Equatable { let content: String }

        var parser = KVSSEParser()
        let events = parser.parse(Data("data: {\"content\":\"hi\"}\n\n".utf8))

        XCTAssertEqual(try events[0].decode(Delta.self), Delta(content: "hi"))
    }

    func testDecodeFailureIsReportedAsDecodingFailed() {
        struct Delta: Decodable { let content: String }

        let event = KVServerSentEvent(data: "not json")

        XCTAssertThrowsError(try event.decode(Delta.self)) { error in
            guard case .decodingFailed = error as? KVAPIClientError else {
                return XCTFail("Expected decodingFailed, got \(error)")
            }
        }
    }
}
