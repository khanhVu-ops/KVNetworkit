//
//  KVLoggingInterceptor+Streaming.swift
//  KVNetworkit
//

import Foundation

// MARK: - Stream logging

/// Streaming half of ``KVLoggingInterceptor``: the same instance you already pass to
/// ``KVAPIClient`` logs streams too, honoring the same level, redaction and truncation.
///
/// ```
/// 📡 ━━━━━━━━━━ STREAM OPEN [200] ━━━━━━━━━━
/// URL: https://api.example.com/chat/stream
/// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
///
/// 🏁 ━━━━━━━━━━ STREAM CLOSED [12 chunks · 486 B · 1.83s] ━━━━━━━━━━
/// data: {"type":"chunk","content":"xin "}
/// data: {"type":"chunk","content":"chào"}
/// data: [DONE]
/// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
/// ```
extension KVLoggingInterceptor: KVStreamInterceptorProtocol {

    public func streamDidOpen(id: String, response: URLResponse) async {
        guard isEnabled, level >= .basic else { return }
        output(streamOpenLog(for: response))
    }

    public func stream(id: String, didReceive chunk: Data) async throws -> Data? {
        guard isEnabled, level >= .body else { return nil }

        switch streamBodyLogging {
        case .none:
            break
        case .aggregated:
            // Capped so a long-running stream cannot grow the log buffer without bound.
            streamBuffers.append(chunk, for: id, limit: maxBodyLogLength)
        case .perChunk:
            output(streamChunkLog(chunk))
        }

        // Logging never rewrites the body.
        return nil
    }

    public func streamDidClose(id: String, statistics: KVStreamStatistics, error: (any Error)?) async {
        // Always drain the buffer, even when logging is off, so nothing is retained.
        let buffered = streamBuffers.take(id)

        guard isEnabled, level >= .basic else { return }
        output(streamCloseLog(statistics: statistics, error: error, body: buffered))
    }
}

// MARK: - Formatting

private extension KVLoggingInterceptor {

    func streamOpenLog(for response: URLResponse) -> String {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        var lines: [String] = []
        lines.append("")
        lines.append("📡 ━━━━━━━━━━ STREAM OPEN [\(statusCode)] ━━━━━━━━━━")
        lines.append("URL: \(response.url?.absoluteString ?? "<no url>")")

        if level >= .headers, let http = response as? HTTPURLResponse {
            let headers = http.allHeaderFields
                .compactMap { key, value -> String? in
                    guard let key = key as? String else { return nil }
                    return "  \(key): \(redactedIfNeeded(header: key, value: "\(value)"))"
                }
                .sorted()
            if !headers.isEmpty {
                lines.append("Headers:")
                lines.append(contentsOf: headers)
            }
        }

        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        return lines.joined(separator: "\n")
    }

    func streamChunkLog(_ chunk: Data) -> String {
        let text = String(data: chunk, encoding: .utf8) ?? "<\(chunk.count) bytes of binary data>"
        return "📡 chunk (\(chunk.count) B): \(truncated(text))"
    }

    func streamCloseLog(statistics: KVStreamStatistics, error: (any Error)?, body: Data?) -> String {
        let emoji = error == nil ? "🏁" : "❌"
        let duration = String(format: "%.2fs", statistics.duration)

        var lines: [String] = []
        lines.append("")
        lines.append(
            "\(emoji) ━━━━━━━━━━ STREAM CLOSED "
            + "[\(statistics.chunkCount) chunks · \(statistics.byteCount) B · \(duration)] "
            + "━━━━━━━━━━"
        )

        if let error {
            lines.append("Error: \(error.localizedDescription)")
        }

        if level >= .body, streamBodyLogging == .aggregated, let body, !body.isEmpty {
            lines.append(prettyBody(from: body))
        }

        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Buffer store

/// Accumulates streamed bodies per request id for ``KVLoggingInterceptor/StreamBodyLogging/aggregated``.
///
/// One interceptor instance can serve several concurrent streams, so buffers are keyed
/// by the request id rather than kept as a single running buffer.
final class KVStreamLogBuffers: @unchecked Sendable {

    private let lock = NSLock()
    private var buffers: [String: Data] = [:]

    /// Appends up to `limit` bytes; anything past the limit is dropped, since the log
    /// output would be truncated at that point anyway.
    func append(_ data: Data, for id: String, limit: Int) {
        lock.lock()
        defer { lock.unlock() }

        var buffer = buffers[id] ?? Data()
        guard buffer.count < limit else { return }
        buffer.append(data.prefix(limit - buffer.count))
        buffers[id] = buffer
    }

    /// Removes and returns the buffer for `id`.
    func take(_ id: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return buffers.removeValue(forKey: id)
    }
}
