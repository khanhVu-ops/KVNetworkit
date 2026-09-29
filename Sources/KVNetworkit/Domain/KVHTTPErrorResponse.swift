//
//  KVHTTPErrorResponse.swift
//  KVNetworkit
//

import Foundation

/// A non-2xx response, with everything the server sent back.
///
/// ``KVAPIClientError/serverMessage(message:statusCode:)`` keeps only the message; use this
/// when the error payload carries more than that — for example
/// `{"detail": "Insufficient credits", "extra": {"requiredCredits": 120}}`.
///
/// ``KVAPIClient`` hands every error response to its `errorResponseMapper`. Return the value
/// itself (it is an `Error`) to throw it, or map it to your own error type:
///
/// ```swift
/// let client = KVAPIClient(errorResponseMapper: { response in
///     response.statusCode == 402 ? response : nil      // nil: default mapping
/// })
///
/// do {
///     try await client.request(ChatEndpoint.send(text))
/// } catch let error as KVHTTPErrorResponse {
///     let credits = try error.decode(CreditsError.self)
/// }
/// ```
public struct KVHTTPErrorResponse: Error, LocalizedError, Sendable {
    /// The HTTP status code.
    public let statusCode: Int

    /// The raw response body, which may be empty or non-JSON (e.g. a `text/plain` traceback).
    public let data: Data

    /// Response headers.
    public let headers: [String: String]

    /// The URL that produced the response.
    public let url: URL?

    /// The server's message, extracted from common payload shapes when the body is JSON.
    public let message: String?

    public init(statusCode: Int, data: Data, headers: [String: String] = [:], url: URL? = nil) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
        self.url = url
        self.message = KVServerErrorMessage.extract(from: data)
    }

    init(response: HTTPURLResponse, data: Data) {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                result[key] = value
            }
        }
        self.init(statusCode: response.statusCode, data: data, headers: headers, url: response.url)
    }

    /// Decodes the error body.
    public func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(T.self, from: data)
    }

    /// The body as UTF-8 text, when it is text.
    public var text: String? {
        String(data: data, encoding: .utf8)
    }

    /// The ``KVAPIClientError`` the client throws for this response by default.
    public var clientError: KVAPIClientError {
        if let message {
            return .serverMessage(message: message, statusCode: statusCode)
        }
        return .statusCode(statusCode)
    }

    public var errorDescription: String? {
        clientError.errorDescription
    }
}

/// Turns an error response into the error thrown to the caller.
/// Return `nil` to fall back to the default ``KVAPIClientError``.
public typealias KVErrorResponseMapper = @Sendable (KVHTTPErrorResponse) -> (any Error)?
