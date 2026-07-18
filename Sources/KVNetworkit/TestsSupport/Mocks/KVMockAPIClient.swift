//
//  KVMockAPIClient.swift
//  KVNetworkit
//

import Foundation

/// A ``KVAPIClientProtocol`` mock that serves stubbed responses keyed by endpoint path.
///
/// ```swift
/// let mock = KVMockAPIClient()
/// mock.stub(path: "/users/me", with: User(id: "1", name: "Khanh"))
/// let user: User = try await mock.request(UserEndpoint.profile)
/// ```
public final class KVMockAPIClient: KVAPIClientProtocol, @unchecked Sendable {

    public let interceptors: [any KVNetworkInterceptorProtocol] = []
    public let session: any KVNetworkSessionProtocol = KVMockNetworkSession()

    private let lock = NSLock()
    private var stubbedValues: [String: any Encodable] = [:]
    private var stubbedData: [String: Data] = [:]
    private var _requestedPaths: [String] = []

    /// When set, every request throws this error.
    public var stubbedError: Error?

    public init() {}

    /// Paths requested so far, in order.
    public var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedPaths
    }

    /// Stubs a decodable response for an endpoint path.
    public func stub(path: String, with value: any Encodable) {
        lock.lock()
        defer { lock.unlock() }
        stubbedValues[path] = value
    }

    /// Stubs raw data for an endpoint path (used by the data-returning request method).
    public func stub(path: String, with data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stubbedData[path] = data
    }

    /// Clears all stubs, recorded paths and the stubbed error.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        stubbedValues.removeAll()
        stubbedData.removeAll()
        _requestedPaths.removeAll()
        stubbedError = nil
    }

    // MARK: - KVAPIClientProtocol

    public func request<T: Decodable>(
        _ endpoint: any KVAPIEndpointProtocol,
        decoder: JSONDecoder,
        id: String
    ) async throws -> T {
        try throwIfStubbed()
        recordRequest(endpoint.path)

        guard let value = stubbedValue(for: endpoint.path) else {
            throw KVAPIClientError.statusCode(404)
        }
        if let typed = value as? T {
            return typed
        }
        let data = try JSONEncoder().encode(value)
        return try decoder.decode(T.self, from: data)
    }

    public func request(
        _ endpoint: any KVAPIEndpointProtocol,
        id: String
    ) async throws {
        try throwIfStubbed()
        recordRequest(endpoint.path)
    }

    @discardableResult
    public func request(
        _ endpoint: any KVAPIEndpointProtocol,
        progressDelegate: (any KVUploadProgressDelegateProtocol)?,
        id: String
    ) async throws -> Data? {
        try throwIfStubbed()
        recordRequest(endpoint.path)
        return stubbedRawData(for: endpoint.path)
    }

    public func cancelRequest(with id: String) {}
    public func cancelAllRequests() {}

    // MARK: - Private

    private func throwIfStubbed() throws {
        if let stubbedError { throw stubbedError }
    }

    private func recordRequest(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        _requestedPaths.append(path)
    }

    private func stubbedValue(for path: String) -> (any Encodable)? {
        lock.lock()
        defer { lock.unlock() }
        return stubbedValues[path]
    }

    private func stubbedRawData(for path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stubbedData[path]
    }
}
