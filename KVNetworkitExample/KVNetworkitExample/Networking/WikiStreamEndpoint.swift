import Foundation
import KVNetworkit

/// Wikimedia EventStreams — a real, public, keyless `text/event-stream` endpoint.
///
/// It never stops sending, which makes it a good demo of the two things that matter
/// for a streaming API: rendering events as they arrive, and cancelling cleanly.
enum WikiStreamEndpoint: KVAPIEndpointProtocol {
    case recentChanges

    var baseURL: String { "https://stream.wikimedia.org" }
    var apiVersion: String { "/v2" }

    var path: String {
        switch self {
        case .recentChanges: return "/stream/recentchange"
        }
    }

    var method: KVHTTPMethod { .get }

    /// Never cache a stream: a partial response is not a cacheable one.
    /// (`KVAPIClient` bypasses the cache for streams regardless — this documents intent.)
    var cachePolicy: KVCachePolicy { .ignore }

    /// The transport timeout is an *inactivity* timeout, and a live stream can idle
    /// between events, so give it more room than a regular request.
    var timeout: TimeInterval? { 120 }
}
