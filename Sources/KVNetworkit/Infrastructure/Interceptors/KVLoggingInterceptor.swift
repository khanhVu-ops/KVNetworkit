//
//  KVLoggingInterceptor.swift
//  KVNetworkit
//

import Foundation

/// Logs outgoing requests as replayable cURL commands and incoming responses
/// as pretty-printed JSON.
///
/// Sensitive headers (`Authorization`, `Cookie`, anything named like `*key*`, `*token*`,
/// `*secret*`, ...) are fully redacted by default.
/// Logging is compiled in but disabled in release builds unless `logsInRelease` is set.
///
/// ```swift
/// // Default: full body logging in DEBUG, silent in release.
/// let client = KVAPIClient(interceptors: [KVLoggingInterceptor()])
///
/// // Route into os.Logger / a file instead of the console:
/// KVLoggingInterceptor(output: { logger.debug("\($0)") })
/// ```
public struct KVLoggingInterceptor: KVNetworkInterceptorProtocol {

    /// How much detail is logged.
    public enum Level: Int, Sendable, Comparable {
        /// Log nothing.
        case none = 0
        /// Method, URL and status code only.
        case basic = 1
        /// `basic` plus headers.
        case headers = 2
        /// `headers` plus bodies (cURL `-d` and response JSON).
        case body = 3

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// How the body of a *streaming* response is logged.
    ///
    /// A stream has no single response body to print, so it gets its own setting.
    /// Only applies at ``Level/body``.
    public enum StreamBodyLogging: Sendable {
        /// Log the open/close lines only — no body.
        case none
        /// Buffer the chunks and log the whole body once, when the stream closes.
        /// This is the closest match to how a non-streamed response is logged.
        case aggregated
        /// Log every chunk as it arrives. Noisy for token streams, but the only way
        /// to see how a server actually frames its events.
        case perChunk
    }

    // Internal rather than private: the streaming half of this interceptor lives in
    // `KVLoggingInterceptor+Streaming.swift`.
    let level: Level
    let maxBodyLogLength: Int
    let output: @Sendable (String) -> Void

    private let redactsSensitiveHeaders: Bool
    private let sensitiveHeaders: Set<String>
    private let sensitiveHeaderKeywords: Set<String>
    private let logsInRelease: Bool

    let streamBodyLogging: StreamBodyLogging

    /// Per-stream accumulation for ``StreamBodyLogging/aggregated``. A reference type so
    /// copies of this (value-type) interceptor share one set of buffers.
    let streamBuffers = KVStreamLogBuffers()

    /// - Parameters:
    ///   - level: Detail level. Defaults to `.body`.
    ///   - redactsSensitiveHeaders: Masks values of `sensitiveHeaders`. Defaults to `true`.
    ///     Disable temporarily when you need a copy-paste-runnable cURL with real credentials.
    ///   - sensitiveHeaders: Case-insensitive header names to redact.
    ///   - sensitiveHeaderKeywords: Also redact any header whose name contains one of these,
    ///     case-insensitively — catches `X-API-Key`, `X-Auth-Token`, `Client-Secret` and the like
    ///     without listing each one. Pass `[]` to match `sensitiveHeaders` exactly.
    ///   - maxBodyLogLength: Bodies longer than this are truncated. Defaults to 10 000 characters.
    ///   - logsInRelease: Also log in release builds. Defaults to `false`.
    ///   - streamBodyLogging: How streaming bodies are logged. Defaults to `.aggregated`.
    ///   - output: Log sink. Defaults to `print`.
    public init(
        level: Level = .body,
        redactsSensitiveHeaders: Bool = true,
        sensitiveHeaders: Set<String> = ["authorization", "cookie", "set-cookie", "x-api-key", "proxy-authorization"],
        sensitiveHeaderKeywords: Set<String> = ["key", "token", "secret"],
        maxBodyLogLength: Int = 10_000,
        logsInRelease: Bool = false,
        streamBodyLogging: StreamBodyLogging = .aggregated,
        output: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.streamBodyLogging = streamBodyLogging
        self.level = level
        self.redactsSensitiveHeaders = redactsSensitiveHeaders
        self.sensitiveHeaders = Set(sensitiveHeaders.map { $0.lowercased() })
        self.sensitiveHeaderKeywords = Set(sensitiveHeaderKeywords.map { $0.lowercased() }.filter { !$0.isEmpty })
        self.maxBodyLogLength = maxBodyLogLength
        self.logsInRelease = logsInRelease
        self.output = output
    }

    public func intercept(request: URLRequest) async throws -> URLRequest {
        if isEnabled, level >= .basic {
            output(requestLog(for: request))
        }
        return request
    }

    public func intercept(response: URLResponse?, data: Data?) async throws -> (URLResponse?, Data?) {
        if isEnabled, level >= .basic {
            output(responseLog(for: response, data: data))
        }
        return (response, data)
    }
}

// MARK: - Formatting

extension KVLoggingInterceptor {

    var isEnabled: Bool {
        guard level != .none else { return false }
        #if DEBUG
        return true
        #else
        return logsInRelease
        #endif
    }

    func requestLog(for request: URLRequest) -> String {
        var lines: [String] = []
        lines.append("")
        lines.append("🌐 ━━━━━━━━━━ REQUEST ━━━━━━━━━━")
        lines.append("\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "<no url>")")
        if level >= .headers {
            lines.append(curlCommand(for: request))
        }
        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        return lines.joined(separator: "\n")
    }

    /// Builds a cURL command that reproduces the request.
    func curlCommand(for request: URLRequest) -> String {
        guard let url = request.url else { return "curl <invalid url>" }

        var components = ["curl -v"]

        if let method = request.httpMethod, method != "GET" {
            components.append("-X \(method)")
        }

        for (key, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            let displayed = redactedIfNeeded(header: key, value: value)
            components.append("-H \"\(key): \(escapeForCURL(displayed))\"")
        }

        if level >= .body, let body = request.httpBody, !body.isEmpty {
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.hasPrefix("multipart/form-data") {
                components.append("--data-binary '<\(body.count) bytes of multipart form data>'")
            } else if let bodyString = String(data: body, encoding: .utf8) {
                components.append("-d \"\(escapeForCURL(truncated(bodyString)))\"")
            } else {
                components.append("--data-binary '<\(body.count) bytes of binary data>'")
            }
        }

        components.append("\"\(url.absoluteString)\"")

        return components.joined(separator: " \\\n  ")
    }

    func responseLog(for response: URLResponse?, data: Data?) -> String {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let statusEmoji = (200..<300).contains(statusCode) ? "✅" : "❌"

        var lines: [String] = []
        lines.append("")
        lines.append("\(statusEmoji) ━━━━━━━━━━ RESPONSE [\(statusCode)] ━━━━━━━━━━")
        lines.append("URL: \(response?.url?.absoluteString ?? "<no url>")")

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

        if level >= .body, let data, !data.isEmpty {
            lines.append(prettyBody(from: data))
        }

        lines.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        return lines.joined(separator: "\n")
    }

    func prettyBody(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: prettyData, encoding: .utf8) {
            return truncated(prettyString)
        }
        if let rawString = String(data: data, encoding: .utf8) {
            return truncated(rawString)
        }
        return "<\(data.count) bytes of binary data>"
    }

    /// Masks the whole value: even a prefix of a credential (`Bearer eyJhbGciOi…`) can leak
    /// enough to identify or narrow down a secret.
    func redactedIfNeeded(header key: String, value: String) -> String {
        guard redactsSensitiveHeaders, isSensitive(header: key) else {
            return value
        }
        return "••••••"
    }

    func isSensitive(header key: String) -> Bool {
        let name = key.lowercased()
        return sensitiveHeaders.contains(name) || sensitiveHeaderKeywords.contains { name.contains($0) }
    }

    func escapeForCURL(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    func truncated(_ text: String) -> String {
        guard text.count > maxBodyLogLength else { return text }
        return text.prefix(maxBodyLogLength) + "\n… <truncated, \(text.count) characters total>"
    }
}
