//
//  KVLoggingInterceptor.swift
//  KVNetworkit
//

import Foundation

/// Logs outgoing requests as replayable cURL commands and incoming responses
/// as pretty-printed JSON.
///
/// Sensitive headers (`Authorization`, `Cookie`, ...) are redacted by default.
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

    private let level: Level
    private let redactsSensitiveHeaders: Bool
    private let sensitiveHeaders: Set<String>
    private let maxBodyLogLength: Int
    private let logsInRelease: Bool
    private let output: @Sendable (String) -> Void

    /// - Parameters:
    ///   - level: Detail level. Defaults to `.body`.
    ///   - redactsSensitiveHeaders: Masks values of `sensitiveHeaders`. Defaults to `true`.
    ///     Disable temporarily when you need a copy-paste-runnable cURL with real credentials.
    ///   - sensitiveHeaders: Case-insensitive header names to redact.
    ///   - maxBodyLogLength: Bodies longer than this are truncated. Defaults to 10 000 characters.
    ///   - logsInRelease: Also log in release builds. Defaults to `false`.
    ///   - output: Log sink. Defaults to `print`.
    public init(
        level: Level = .body,
        redactsSensitiveHeaders: Bool = true,
        sensitiveHeaders: Set<String> = ["authorization", "cookie", "set-cookie", "x-api-key", "proxy-authorization"],
        maxBodyLogLength: Int = 10_000,
        logsInRelease: Bool = false,
        output: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.level = level
        self.redactsSensitiveHeaders = redactsSensitiveHeaders
        self.sensitiveHeaders = Set(sensitiveHeaders.map { $0.lowercased() })
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

private extension KVLoggingInterceptor {

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

    func redactedIfNeeded(header key: String, value: String) -> String {
        guard redactsSensitiveHeaders, sensitiveHeaders.contains(key.lowercased()) else {
            return value
        }
        let visiblePrefix = value.prefix(12)
        return "\(visiblePrefix)••••••"
    }

    func escapeForCURL(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    func truncated(_ text: String) -> String {
        guard text.count > maxBodyLogLength else { return text }
        return text.prefix(maxBodyLogLength) + "\n… <truncated, \(text.count) characters total>"
    }
}
