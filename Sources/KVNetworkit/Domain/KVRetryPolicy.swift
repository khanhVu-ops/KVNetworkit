//
//  KVRetryPolicy.swift
//  KVNetworkit
//

import Foundation

/// Describes if and how failed requests are retried by ``KVAPIClient``.
///
/// Retries use exponential backoff with jitter: `baseDelay * 2^(attempt-1)`,
/// capped at `maxDelay`, with ±20% random jitter to avoid thundering herds. A
/// `Retry-After` header on the failed response takes precedence, still capped at `maxDelay`.
///
/// Only idempotent methods are retried by default: replaying a `POST` or `PATCH` the server
/// may already have applied can duplicate its side effects (a second order, a second charge).
/// Opt a method in with `retryableMethods`, or per endpoint with
/// ``KVAPIEndpointProtocol/retryPolicy``.
///
/// ```swift
/// let client = KVAPIClient(retryPolicy: .default)          // 2 retries
/// let client = KVAPIClient(retryPolicy: KVRetryPolicy(maxRetries: 4, baseDelay: 0.5))
/// ```
public struct KVRetryPolicy: Sendable {

    /// Maximum number of retries after the initial attempt.
    public let maxRetries: Int

    /// Base delay (seconds) before the first retry.
    public let baseDelay: TimeInterval

    /// Upper bound (seconds) for any single retry delay.
    public let maxDelay: TimeInterval

    /// HTTP status codes that trigger a retry.
    public let retryableStatusCodes: Set<Int>

    /// Transport error codes that trigger a retry.
    public let retryableURLErrorCodes: Set<URLError.Code>

    /// HTTP methods that may be retried at all. Defaults to ``idempotentMethods``.
    public let retryableMethods: Set<KVHTTPMethod>

    /// Methods that are safe to replay (RFC 9110 §9.2.2): `GET`, `HEAD`, `PUT`, `DELETE`,
    /// `OPTIONS`, `TRACE`.
    public static let idempotentMethods: Set<KVHTTPMethod> = [.get, .head, .put, .delete, .options, .trace]

    /// No retries. The initial attempt is the only attempt.
    public static let never = KVRetryPolicy(maxRetries: 0)

    /// Two retries with a 1-second base delay.
    public static let `default` = KVRetryPolicy(maxRetries: 2)

    public init(
        maxRetries: Int,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504],
        retryableURLErrorCodes: Set<URLError.Code> = [
            .timedOut,
            .networkConnectionLost,
            .notConnectedToInternet,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed
        ],
        retryableMethods: Set<KVHTTPMethod> = KVRetryPolicy.idempotentMethods
    ) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.retryableStatusCodes = retryableStatusCodes
        self.retryableURLErrorCodes = retryableURLErrorCodes
        self.retryableMethods = retryableMethods
    }

    /// Whether requests with the given HTTP method (e.g. `"POST"`) may be retried.
    /// A request without a method is a `GET`.
    public func shouldRetry(method: String?) -> Bool {
        guard let method = KVHTTPMethod(rawValue: (method ?? "GET").uppercased()) else { return false }
        return retryableMethods.contains(method)
    }

    /// Whether a response with the given status code should be retried.
    public func shouldRetry(statusCode: Int) -> Bool {
        maxRetries > 0 && retryableStatusCodes.contains(statusCode)
    }

    /// Whether the given error should be retried. Cancellation is never retried.
    public func shouldRetry(error: Error) -> Bool {
        guard maxRetries > 0, !(error is CancellationError) else { return false }

        if let urlError = error as? URLError {
            return retryableURLErrorCodes.contains(urlError.code)
        }
        if let apiError = error as? KVAPIClientError {
            switch apiError {
            case .timeout:
                return true
            case .networkError(let urlError):
                return retryableURLErrorCodes.contains(urlError.code)
            default:
                return false
            }
        }
        return false
    }

    /// The backoff delay (seconds) before the given retry attempt (1-based).
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponential = baseDelay * pow(2.0, Double(max(0, attempt - 1)))
        let capped = min(exponential, maxDelay)
        let jitter = capped * Double.random(in: -0.2...0.2)
        return max(0, capped + jitter)
    }

    /// The delay (seconds) before the given retry attempt, honouring the server's
    /// `Retry-After` header (delta-seconds or an HTTP date) when present.
    ///
    /// The header value is capped at `maxDelay`, so a server cannot park the caller for
    /// hours. Without a usable header this is ``delay(forAttempt:)``.
    public func delay(forAttempt attempt: Int, retryAfter: String?) -> TimeInterval {
        guard let requested = retryAfter.flatMap({ Self.parseRetryAfter($0) }) else {
            return delay(forAttempt: attempt)
        }
        return min(max(0, requested), maxDelay)
    }

    /// Parses `Retry-After: 120` or `Retry-After: Wed, 21 Oct 2015 07:28:00 GMT`.
    static func parseRetryAfter(_ value: String, now: Date = Date()) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: trimmed).map { $0.timeIntervalSince(now) }
    }
}
