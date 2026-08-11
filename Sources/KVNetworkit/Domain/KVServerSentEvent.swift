//
//  KVServerSentEvent.swift
//  KVNetworkit
//

import Foundation

/// One event parsed out of a streaming response.
///
/// For ``KVStreamFraming/jsonLines`` streams only ``data`` is populated —
/// the other fields have no equivalent in that format.
public struct KVServerSentEvent: Sendable, Equatable {

    /// The `event:` field, e.g. `message_delta`. `nil` when the server omits it.
    public let event: String?

    /// The payload: the `data:` field(s), joined with `\n` when the event spans
    /// several `data:` lines.
    public let data: String

    /// The `id:` field, i.e. the last event id sent by the server.
    ///
    /// Per the SSE spec the id persists across events until the server changes it,
    /// so this is the *current* id rather than only the one sent with this event.
    public let id: String?

    /// The `retry:` field in milliseconds, when the server sent one.
    public let retry: Int?

    public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }

    /// `true` when the payload is the `[DONE]` sentinel used by OpenAI-style APIs
    /// to mark the end of a stream.
    public var isDoneSentinel: Bool {
        data == "[DONE]"
    }

    /// Decodes ``data`` as JSON into `T`.
    ///
    /// - Throws: ``KVAPIClientError/decodingFailed(_:)`` when the payload is not
    ///   valid JSON for `T`.
    public func decode<T: Decodable>(
        _ type: T.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        do {
            return try decoder.decode(T.self, from: Data(data.utf8))
        } catch {
            throw KVAPIClientError.decodingFailed(error)
        }
    }
}
