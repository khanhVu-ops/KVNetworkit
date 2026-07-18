//
//  KVAPIClientProtocol.swift
//  KVNetworkit
//

import Foundation

/// An API client that sends requests to ``KVAPIEndpointProtocol`` endpoints
/// and decodes their responses.
///
/// All methods are asynchronous and throw ``KVAPIClientError`` on failure.
public protocol KVAPIClientProtocol: Sendable {
    /// The interceptors applied to every request/response, in order.
    var interceptors: [any KVNetworkInterceptorProtocol] { get }

    /// The underlying network session.
    var session: any KVNetworkSessionProtocol { get }

    /// Sends a request and decodes the response body into `T`.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint to request.
    ///   - decoder: The decoder used for the response body.
    ///   - id: A unique identifier for the request, usable with ``cancelRequest(with:)``.
    func request<T: Decodable>(
        _ endpoint: any KVAPIEndpointProtocol,
        decoder: JSONDecoder,
        id: String
    ) async throws -> T

    /// Sends a request where only success/failure matters (POST, DELETE, PATCH, ...).
    func request(
        _ endpoint: any KVAPIEndpointProtocol,
        id: String
    ) async throws

    /// Sends a request and returns the raw response data, optionally reporting upload progress.
    @discardableResult
    func request(
        _ endpoint: any KVAPIEndpointProtocol,
        progressDelegate: (any KVUploadProgressDelegateProtocol)?,
        id: String
    ) async throws -> Data?

    /// Cancels the in-flight request with the given identifier.
    func cancelRequest(with id: String)

    /// Cancels all in-flight requests started by this client.
    func cancelAllRequests()
}

// MARK: - Convenience overloads

public extension KVAPIClientProtocol {
    /// Sends a request and decodes the response with a default `JSONDecoder` and a random id.
    func request<T: Decodable>(
        _ endpoint: any KVAPIEndpointProtocol,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        try await request(endpoint, decoder: decoder, id: UUID().uuidString)
    }

    /// Sends a fire-and-check request with a random id.
    func request(_ endpoint: any KVAPIEndpointProtocol) async throws {
        try await request(endpoint, id: UUID().uuidString)
    }

    /// Sends a raw-data request with a random id.
    @discardableResult
    func request(
        _ endpoint: any KVAPIEndpointProtocol,
        progressDelegate: (any KVUploadProgressDelegateProtocol)?
    ) async throws -> Data? {
        try await request(endpoint, progressDelegate: progressDelegate, id: UUID().uuidString)
    }
}
