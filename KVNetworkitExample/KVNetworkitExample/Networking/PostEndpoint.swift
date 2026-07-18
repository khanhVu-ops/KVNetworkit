import Foundation
import KVNetworkit

enum PostEndpoint: KVAPIEndpointProtocol {
    case fetchAll
    case fetchOne(id: Int)
    case create(title: String, body: String, userId: Int)

    var baseURL: String { "https://jsonplaceholder.typicode.com" }
    var apiVersion: String { "" }
    var headers: [String: String] { ["Content-Type": "application/json"] }
    var timeout: TimeInterval? { nil }

    var method: KVHTTPMethod {
        switch self {
        case .fetchAll, .fetchOne: return .get
        case .create: return .post
        }
    }

    var path: String {
        switch self {
        case .fetchAll: return "/posts"
        case .fetchOne(let id): return "/posts/\(id)"
        case .create: return "/posts"
        }
    }

    var urlParams: [String: any CustomStringConvertible] { [:] }

    var body: KVHTTPBody? {
        switch self {
        case .fetchAll, .fetchOne:
            return nil
        case .create(let title, let body, let userId):
            let payload = CreatePostRequest(title: title, body: body, userId: userId)
            return try? .jsonEncoded(payload)
        }
    }

    // Cache GET /posts for 60 seconds, individual posts for 5 minutes
    var cachePolicy: KVCachePolicy {
        switch self {
        case .fetchAll: return .networkFirst(ttl: 60)
        case .fetchOne: return .cacheFirst(ttl: 300)
        case .create: return .ignore
        }
    }
}
