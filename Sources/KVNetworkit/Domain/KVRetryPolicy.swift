//
//  KVRetryPolicy.swift
//  KVNetworkit
//

import Foundation

/// Describes if and how failed requests are retried by ``KVAPIClient``.
///
/// Retries use exponential backoff with jitter: `baseDelay * 2^(attempt-1)`,
/// capped at `maxDelay`, with ±20% random jitter to avoid thundering herds.
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
        ]
    ) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.retryableStatusCodes = retryableStatusCodes
        self.retryableURLErrorCodes = retryableURLErrorCodes
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
}
