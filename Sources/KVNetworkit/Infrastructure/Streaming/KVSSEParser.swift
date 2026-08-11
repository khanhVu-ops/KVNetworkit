//
//  KVSSEParser.swift
//  KVNetworkit
//

import Foundation

/// An incremental parser that turns streaming `Data` chunks into ``KVServerSentEvent`` values.
///
/// The parser is a value type and keeps no I/O of its own, which makes it usable
/// on any byte source — and trivial to unit-test. ``KVAPIClient`` uses it for
/// `streamEvents(_:)`; reach for it directly only when you drive a stream yourself.
///
/// ```swift
/// var parser = KVSSEParser()
/// for try await chunk in stream {
///     for event in parser.parse(chunk) where !event.isDoneSentinel {
///         print(try event.decode(Delta.self).text)
///     }
/// }
/// for event in parser.finish() { ... }   // trailing frame without blank line
/// ```
public struct KVSSEParser: Sendable {

    private let framing: KVStreamFraming

    private var accumulator = KVLineAccumulator()
    private var dataLines: [String] = []
    private var eventType: String?
    private var lastEventId: String?
    private var retry: Int?

    /// - Parameter framing: How events are delimited. Defaults to spec-compliant SSE.
    public init(framing: KVStreamFraming = .serverSentEvents) {
        self.framing = framing
    }

    /// Parses a chunk and returns every event it completed.
    public mutating func parse(_ data: Data) -> [KVServerSentEvent] {
        var events: [KVServerSentEvent] = []
        for line in accumulator.lines(from: data) {
            events.append(contentsOf: handle(line: line))
        }
        return events
    }

    /// Flushes any buffered line and pending frame once the stream has ended.
    ///
    /// Servers routinely omit the trailing blank line (and sometimes the trailing
    /// newline), so calling this is required to avoid losing the last event.
    public mutating func finish() -> [KVServerSentEvent] {
        var events: [KVServerSentEvent] = []
        if let tail = accumulator.flush() {
            events.append(contentsOf: handle(line: tail))
        }
        if let event = dispatch() {
            events.append(event)
        }
        return events
    }

    // MARK: - Line handling

    private mutating func handle(line rawLine: String) -> [KVServerSentEvent] {
        var line = rawLine
        // A lone `\r` terminator already stripped the newline, but a server may also
        // send stray whitespace at the end of a field.
        if line.hasSuffix("\r") { line.removeLast() }

        if framing == .jsonLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return [] }
            return [KVServerSentEvent(data: trimmed)]
        }

        // Blank line: dispatch the accumulated frame.
        if line.isEmpty {
            return dispatch().map { [$0] } ?? []
        }

        // Comment / keep-alive ping.
        if line.hasPrefix(":") { return [] }

        let (field, value) = Self.splitField(line)

        switch field {
        case "data":
            dataLines.append(value)
            // Relaxed framing: the server never sends the blank separator line.
            if framing == .serverSentEventsPerLine {
                return dispatch().map { [$0] } ?? []
            }
        case "event":
            eventType = value.isEmpty ? nil : value
        case "id":
            // The spec requires ignoring ids containing a NUL character.
            if !value.contains("\0") { lastEventId = value }
        case "retry":
            if let milliseconds = Int(value) { retry = milliseconds }
        default:
            break // Unknown fields are ignored per spec.
        }

        return []
    }

    /// Emits the accumulated frame, or `nil` when there is no payload to emit.
    private mutating func dispatch() -> KVServerSentEvent? {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            eventType = nil
        }

        guard !dataLines.isEmpty else { return nil }

        return KVServerSentEvent(
            event: eventType,
            data: dataLines.joined(separator: "\n"),
            id: lastEventId,
            retry: retry
        )
    }

    /// Splits `field: value`, dropping a single space after the colon per spec.
    /// A line without a colon is a field name with an empty value.
    private static func splitField(_ line: String) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else {
            return (line, "")
        }
        let field = String(line[line.startIndex..<colon])
        var value = line[line.index(after: colon)...]
        if value.first == " " { value = value.dropFirst() }
        return (field, String(value))
    }
}
