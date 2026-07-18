//
//  KVAPIClientError.swift
//  KVNetworkit
//

import Foundation

/// An error type representing failures that can occur during API client operations.
public enum KVAPIClientError: Error, LocalizedError, CustomNSError {
    /// The endpoint could not produce a valid `URLRequest`.
    case invalidURL
    /// The request was unauthorized (401) and could not be recovered.
    case unauthorized
    /// The refresh token is invalid or expired.
    case refreshTokenInvalid
    /// The server returned a non-success status code without a parsable message.
    case statusCode(Int)
    /// The response was not a valid HTTP response.
    case invalidResponse(Data)
    /// Decoding the response body into the expected type failed.
    case decodingFailed(Error)
    /// A transport-level `URLError` occurred.
    case networkError(URLError)
    /// The request failed with a general error.
    case requestFailed(Error)
    /// A task with the same identifier is already running.
    case taskInProgress
    /// The task was canceled.
    case taskCanceled
    /// A server-provided error message with its status code.
    case serverMessage(message: String, statusCode: Int)
    /// The request timed out.
    case timeout
    /// No network connection is available.
    case networkUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The request URL is invalid."
        case .unauthorized:
            return "You are not authorized to perform this request."
        case .refreshTokenInvalid:
            return "Your session has expired. Please sign in again."
        case .statusCode(let code):
            return "The server responded with status code \(code)."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .decodingFailed:
            return "The response could not be read."
        case .networkError(let urlError):
            return urlError.localizedDescription
        case .requestFailed(let error):
            return error.localizedDescription
        case .taskInProgress:
            return "This request is already in progress."
        case .taskCanceled:
            return "The request was canceled."
        case .serverMessage(let message, _):
            return message
        case .timeout:
            return "The request timed out. Please try again."
        case .networkUnavailable:
            return "Network is not available. Please check your connection."
        }
    }

    public var errorUserInfo: [String: Any] {
        guard let description = errorDescription else { return [:] }
        return [NSLocalizedDescriptionKey: description]
    }

    /// The HTTP status code associated with the error, if any.
    public var statusCode: Int? {
        switch self {
        case .statusCode(let code), .serverMessage(_, let code):
            return code
        case .unauthorized:
            return 401
        default:
            return nil
        }
    }

    /// `true` when the error is caused by connectivity problems rather than the server.
    ///
    /// Use this to avoid destructive reactions (e.g. logging the user out) on flaky networks.
    public var isNetworkConnectivityError: Bool {
        switch self {
        case .networkError(let urlError):
            return [
                .notConnectedToInternet,
                .networkConnectionLost,
                .dataNotAllowed,
                .internationalRoamingOff
            ].contains(urlError.code)
        case .timeout, .networkUnavailable:
            return true
        default:
            return false
        }
    }
}

public extension Error {
    /// Maps a `KVAPIClientError.serverMessage` into a domain-specific error, leaving other errors untouched.
    ///
    /// ```swift
    /// throw error.mapTo { LoginError.invalidCredentials(message: $0) }
    /// ```
    func mapTo<T: Error>(_ transform: (String) -> T) -> Error {
        if let apiError = self as? KVAPIClientError,
           case let .serverMessage(message, _) = apiError {
            return transform(message)
        }
        return self
    }
}
