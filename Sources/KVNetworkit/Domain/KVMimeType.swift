//
//  KVMimeType.swift
//  KVNetworkit
//

import Foundation

/// Common MIME types for upload payloads.
public enum KVMimeType: String, Sendable {
    // Images
    case jpeg = "image/jpeg"
    case png = "image/png"
    case gif = "image/gif"
    case heic = "image/heic"
    case webp = "image/webp"
    case bmp = "image/bmp"
    case tiff = "image/tiff"
    case svg = "image/svg+xml"

    // Audio / Video
    case mp3 = "audio/mpeg"
    case m4a = "audio/mp4"
    case wav = "audio/wav"
    case mp4 = "video/mp4"
    case mov = "video/quicktime"

    // Documents
    case pdf = "application/pdf"
    case json = "application/json"
    case plainText = "text/plain"
    case octetStream = "application/octet-stream"

    /// The MIME type string.
    public var asString: String { rawValue }
}
