//
//  KVMultipartFormData.swift
//  KVNetworkit
//

import Foundation

/// Builds a `multipart/form-data` request body from text fields and file parts.
///
/// ```swift
/// var form = KVMultipartFormData()
/// form.addField(name: "title", value: "Avatar")
/// form.addFile(name: "file", fileName: "avatar.jpg", mimeType: .jpeg, data: imageData)
///
/// var body: KVHTTPBody? { .multipartFormData(form) }
/// ```
public struct KVMultipartFormData: Sendable {

    /// A single part of the multipart body.
    public struct Part: Sendable {
        public let name: String
        public let fileName: String?
        public let mimeType: String?
        public let data: Data

        public init(name: String, fileName: String? = nil, mimeType: String? = nil, data: Data) {
            self.name = name
            self.fileName = fileName
            self.mimeType = mimeType
            self.data = data
        }
    }

    /// Boundary string separating the parts.
    public let boundary: String

    /// All parts, in the order they will be encoded.
    public private(set) var parts: [Part]

    public init(boundary: String = "kvnetworkit.boundary.\(UUID().uuidString)", parts: [Part] = []) {
        self.boundary = boundary
        self.parts = parts
    }

    /// Convenience initializer for the common single-file-plus-fields upload.
    public init(
        boundary: String = "kvnetworkit.boundary.\(UUID().uuidString)",
        fileData: Data,
        fileName: String,
        mimeType: String,
        fieldName: String = "file",
        parameters: [String: String] = [:]
    ) {
        var parts = parameters
            .sorted { $0.key < $1.key }
            .map { Part(name: $0.key, data: Data($0.value.utf8)) }
        parts.append(Part(name: fieldName, fileName: fileName, mimeType: mimeType, data: fileData))
        self.init(boundary: boundary, parts: parts)
    }

    /// Appends a plain text field.
    public mutating func addField(name: String, value: String) {
        parts.append(Part(name: name, data: Data(value.utf8)))
    }

    /// Appends a file part.
    public mutating func addFile(name: String, fileName: String, mimeType: KVMimeType, data: Data) {
        addFile(name: name, fileName: fileName, mimeType: mimeType.asString, data: data)
    }

    /// Appends a file part with a raw MIME type string.
    public mutating func addFile(name: String, fileName: String, mimeType: String, data: Data) {
        parts.append(Part(name: name, fileName: fileName, mimeType: mimeType, data: data))
    }

    /// The encoded multipart body.
    public var asData: Data {
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let fileName = part.fileName {
                disposition += "; filename=\"\(fileName)\""
            }
            body.append(Data("\(disposition)\r\n".utf8))
            if let mimeType = part.mimeType {
                body.append(Data("Content-Type: \(mimeType)\r\n".utf8))
            }
            body.append(Data("\r\n".utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
