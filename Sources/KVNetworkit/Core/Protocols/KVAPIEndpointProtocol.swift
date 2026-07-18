//
//  KVAPIEndpointProtocol.swift
//  KVNetworkit
//

import Foundation

/// Describes everything needed to build a `URLRequest` for one API endpoint.
///
/// Typical usage is an enum with one case per endpoint:
///
/// ```swift
/// enum UserEndpoint: KVAPIEndpointProtocol {
///     case profile
///     case update(name: String)
///
///     var baseURL: String { "https://api.example.com" }
///     var apiVersion: String { "/api/v1" }
///
///     var path: String {
///         switch self {
///         case .profile, .update: return "/users/me"
///         }
///     }
///
///     var method: KVHTTPMethod {
///         switch self {
///         case .profile: return .get
///         case .update: return .patch
///         }
///     }
///
///     var body: KVHTTPBody? {
///         switch self {
///         case .profile: return nil
///         case .update(let name): return try? .jsonEncoded(["name": name])
///         }
///     }
///
///     var cachePolicy: KVCachePolicy {
///         switch self {
///         case .profile: return .cacheFirst(ttl: 300)
///         case .update: return .ignore
///         }
///     }
/// }
/// ```
public protocol KVAPIEndpointProtocol {
    /// HTTP method used by the endpoint.
    var method: KVHTTPMethod { get }

    /// Path for the endpoint, relative to `baseURL + apiVersion`.
    var path: String { get }

    /// Base URL for the API, e.g. `https://api.example.com`.
    var baseURL: String { get }

    /// API version segment, e.g. `/api/v1`. Defaults to empty.
    var apiVersion: String { get }

    /// Additional HTTP headers. Defaults to empty.
    var headers: [String: String] { get }

    /// URL query parameters. Defaults to empty.
    var urlParams: [String: any CustomStringConvertible] { get }

    /// Request body. Defaults to `nil`.
    var body: KVHTTPBody? { get }

    /// How this endpoint interacts with the client's response cache. Defaults to `.ignore`.
    var cachePolicy: KVCachePolicy { get }

    /// Per-request timeout override. Defaults to `nil` (session timeout applies).
    var timeout: TimeInterval? { get }

    /// The `URLRequest` built from the components above.
    var urlRequest: URLRequest? { get }
}

// MARK: - Defaults

public extension KVAPIEndpointProtocol {
    var apiVersion: String { "" }
    var headers: [String: String] { [:] }
    var urlParams: [String: any CustomStringConvertible] { [:] }
    var body: KVHTTPBody? { nil }
    var cachePolicy: KVCachePolicy { .ignore }
    var timeout: TimeInterval? { nil }

    /// Builds the `URLRequest` from the endpoint components.
    ///
    /// The `Content-Type` header is derived from `body` automatically unless
    /// the endpoint already provides one in `headers`.
    var urlRequest: URLRequest? {
        var components = URLComponents(string: baseURL + apiVersion + path)

        if !urlParams.isEmpty {
            components?.queryItems = urlParams
                .map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }
                .sorted { $0.name < $1.name }
        }

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue

        var allHeaders = headers
        if let body, allHeaders["Content-Type"] == nil {
            allHeaders["Content-Type"] = body.contentType
        }
        request.allHTTPHeaderFields = allHeaders
        request.httpBody = body?.asData

        if let timeout {
            request.timeoutInterval = timeout
        }

        return request
    }
}
