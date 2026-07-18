//
//  KVHTTPBody.swift
//  KVNetworkit
//

import Foundation

/// Represents the supported HTTP request body types.
public enum KVHTTPBody: Sendable {
    /// A raw binary body (`application/octet-stream`).
    case data(Data)

    /// A JSON-encoded body (`application/json`).
    case json(Data)

    /// A URL-encoded form body (`application/x-www-form-urlencoded`).
    case formURLEncoded([String: String])

    /// A multipart form-data body.
    case multipartFormData(KVMultipartFormData)

    /// Encodes an `Encodable` value into a `.json` body.
    ///
    /// - Parameters:
    ///   - value: The value to encode.
    ///   - encoder: The encoder to use. Defaults to `JSONEncoder()`.
    /// - Throws: Any error thrown by the encoder.
    public static func jsonEncoded<T: Encodable>(
        _ value: T,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> KVHTTPBody {
        .json(try encoder.encode(value))
    }

    /// The raw `Data` representation of the body.
    public var asData: Data? {
        switch self {
        case .data(let data), .json(let data):
            return data
        case .formURLEncoded(let fields):
            let encoded = fields
                .map { key, value in
                    let k = key.addingPercentEncoding(withAllowedCharacters: .kvFormURLEncodedAllowed) ?? key
                    let v = value.addingPercentEncoding(withAllowedCharacters: .kvFormURLEncodedAllowed) ?? value
                    return "\(k)=\(v)"
                }
                .sorted()
                .joined(separator: "&")
            return encoded.data(using: .utf8)
        case .multipartFormData(let formData):
            return formData.asData
        }
    }

    /// The `Content-Type` header value corresponding to the body type.
    public var contentType: String {
        switch self {
        case .data:
            return "application/octet-stream"
        case .json:
            return "application/json"
        case .formURLEncoded:
            return "application/x-www-form-urlencoded"
        case .multipartFormData(let formData):
            return "multipart/form-data; boundary=\(formData.boundary)"
        }
    }
}

private extension CharacterSet {
    /// Allowed characters for form-url-encoded keys/values (RFC 3986 unreserved).
    static let kvFormURLEncodedAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
