//
//  KVStreamFraming.swift
//  KVNetworkit
//

import Foundation

/// How a streaming response body is split into discrete events.
///
/// Pick the framing that matches your backend. When in doubt, stream with
/// ``KVStreamFraming/serverSentEvents`` first and inspect the raw lines via
/// `client.streamLines(_:)`.
public enum KVStreamFraming: Sendable, Equatable {
    /// Standard `text/event-stream`: fields (`event:`, `data:`, `id:`, `retry:`)
    /// accumulate until a blank line dispatches the event, and multiple `data:`
    /// lines are joined with `\n`.
    ///
    /// Used by OpenAI, Anthropic and most SSE servers.
    case serverSentEvents

    /// A relaxed `text/event-stream`: every `data:` line is dispatched as its own
    /// event, without waiting for a blank line.
    ///
    /// Use this for backends that emit one JSON payload per line and never send
    /// the blank separator line the SSE spec requires.
    case serverSentEventsPerLine

    /// Newline-delimited JSON (`application/x-ndjson`): every non-empty line is
    /// one payload, with no `data:` prefix.
    case jsonLines

    /// The `Accept` header value that matches this framing.
    ///
    /// Only applied when the endpoint does not declare its own `Accept` header.
    public var acceptHeader: String {
        switch self {
        case .serverSentEvents, .serverSentEventsPerLine:
            return "text/event-stream"
        case .jsonLines:
            return "application/x-ndjson"
        }
    }
}
