//
//  KVUploadProgressDelegate.swift
//  KVNetworkit
//

import Foundation

/// A `URLSession` task delegate that reports upload progress.
public protocol KVUploadProgressDelegateProtocol: URLSessionTaskDelegate, Sendable {}

/// Default implementation that forwards progress (0.0 ... 1.0) to a closure.
///
/// ```swift
/// let delegate = KVUploadProgressDelegate { progress in
///     print("Uploaded \(Int(progress * 100))%")
/// }
/// try await client.request(endpoint, progressDelegate: delegate)
/// ```
public final class KVUploadProgressDelegate: NSObject, KVUploadProgressDelegateProtocol {

    private let progressHandler: (@Sendable (Double) -> Void)?

    /// - Parameter progressHandler: Called with fractional progress as bytes are sent.
    public init(progressHandler: (@Sendable (Double) -> Void)?) {
        self.progressHandler = progressHandler
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        progressHandler?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
