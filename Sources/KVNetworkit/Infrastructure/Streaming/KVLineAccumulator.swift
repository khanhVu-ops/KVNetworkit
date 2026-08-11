//
//  KVLineAccumulator.swift
//  KVNetworkit
//

import Foundation

/// Splits a stream of arbitrary `Data` chunks into complete text lines.
///
/// Network chunks do not align with line boundaries: one chunk can carry three
/// lines and half of a fourth, and a multi-byte UTF-8 character can straddle two
/// chunks. Feed every chunk to ``lines(from:)`` and the accumulator holds back
/// the incomplete tail until the rest arrives.
///
/// `\n`, `\r\n` and a lone `\r` all terminate a line, as required by the
/// server-sent-events spec. A leading UTF-8 BOM is dropped.
///
/// ```swift
/// var accumulator = KVLineAccumulator()
/// for try await chunk in stream {
///     for line in accumulator.lines(from: chunk) { print(line) }
/// }
/// if let tail = accumulator.flush() { print(tail) }
/// ```
public struct KVLineAccumulator: Sendable {

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    private var buffer: [UInt8] = []
    /// `true` when the previous byte was a `\r`, so a following `\n` is part of the
    /// same terminator instead of an empty line.
    private var skipsLeadingLineFeed = false
    private var hasCheckedBOM = false

    public init() {}

    /// Appends a chunk and returns every line it completed.
    public mutating func lines(from data: Data) -> [String] {
        var completed: [String] = []

        for byte in data {
            if skipsLeadingLineFeed {
                skipsLeadingLineFeed = false
                if byte == Self.lineFeed { continue }
            }

            switch byte {
            case Self.lineFeed:
                completed.append(takeLine())
            case Self.carriageReturn:
                skipsLeadingLineFeed = true
                completed.append(takeLine())
            default:
                buffer.append(byte)
            }
        }

        return completed
    }

    /// Returns the trailing line when the stream ended without a final newline.
    ///
    /// Call this once after the stream finishes; servers frequently omit the last
    /// terminator, and the final payload would otherwise be dropped.
    public mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        return takeLine()
    }

    private mutating func takeLine() -> String {
        var bytes = buffer
        buffer.removeAll(keepingCapacity: true)

        if !hasCheckedBOM {
            hasCheckedBOM = true
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
                bytes.removeFirst(3)
            }
        }

        return String(decoding: bytes, as: UTF8.self)
    }
}
