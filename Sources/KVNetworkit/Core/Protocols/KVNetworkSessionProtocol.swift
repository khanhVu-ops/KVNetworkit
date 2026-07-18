//
//  KVNetworkSessionProtocol.swift
//  KVNetworkit
//

import Foundation

/// Abstracts `URLSession` so it can be replaced in tests.
public protocol KVNetworkSessionProtocol: Sendable {
    /// Performs a network request and returns the response data.
    ///
    /// - Parameter request: The `URLRequest` to execute.
    /// - Returns: A tuple containing the response `Data` and the associated `URLResponse`.
    /// - Throws: An error if the network request fails.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}
