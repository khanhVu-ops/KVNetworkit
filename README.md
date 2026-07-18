# KVNetworkit

A clean, protocol-oriented networking package for iOS 16+ built on `async/await`. No third-party dependencies.

## Features

- ✅ **Endpoint-driven requests** — describe an API as an enum, get type-safe `Decodable` responses
- 🔌 **Interceptor pipeline** — auth headers, logging, connectivity checks, custom headers
- 📋 **cURL + response logging** — replayable cURL commands, pretty-printed JSON responses, sensitive-header redaction
- 💾 **Response caching** — memory (LRU), disk, or hybrid; `cacheFirst` / `networkFirst` policies with TTL, per endpoint
- 🔁 **Retry with exponential backoff** — configurable status codes, transport errors, jitter
- 🔑 **Token refresh** — 401 handling with single-flight refresh coordination and loop protection
- 📶 **Network monitoring** — `NWPathMonitor`-backed, observable from SwiftUI on both iOS 16 (`ObservableObject`) and iOS 17+ (`@Observable`)
- ⬆️ **Upload support** — multipart form-data with progress reporting
- ❌ **Cancellation** — cancel individual requests by id, or all at once
- 🧪 **Test support** — mock client, session and interceptor ship with the package

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/<your-org>/KVNetworkit.git", from: "1.0.0")
]
```

## Quick start

### 1. Define an endpoint

```swift
import KVNetworkit

enum UserEndpoint: KVAPIEndpointProtocol {
    case profile
    case update(name: String)
    case uploadAvatar(image: Data)

    var baseURL: String { "https://api.example.com" }
    var apiVersion: String { "/api/v1" }

    var path: String {
        switch self {
        case .profile, .update: return "/users/me"
        case .uploadAvatar: return "/users/me/avatar"
        }
    }

    var method: KVHTTPMethod {
        switch self {
        case .profile: return .get
        case .update: return .patch
        case .uploadAvatar: return .post
        }
    }

    var body: KVHTTPBody? {
        switch self {
        case .profile:
            return nil
        case .update(let name):
            return try? .jsonEncoded(["name": name])
        case .uploadAvatar(let image):
            var form = KVMultipartFormData()
            form.addFile(name: "file", fileName: "avatar.jpg", mimeType: .jpeg, data: image)
            return .multipartFormData(form)
        }
    }

    var cachePolicy: KVCachePolicy {
        switch self {
        case .profile: return .cacheFirst(ttl: 300)   // serve from cache for 5 minutes
        default: return .ignore
        }
    }
}
```

`Content-Type` is derived from `body` automatically. `headers`, `urlParams`, `timeout`, `cachePolicy` all have sensible defaults.

### 2. Create a client

```swift
let client = KVAPIClient(
    interceptors: [
        KVNetworkAwareInterceptor(),                                  // fail fast when offline
        KVAuthInterceptor(tokenProvider: { tokenStore.accessToken }), // Bearer token
        KVLoggingInterceptor()                                        // cURL + response logs (DEBUG only)
    ],
    retryPolicy: .default,        // 2 retries, exponential backoff
    cache: KVHybridCache()        // memory + disk
)
```

### 3. Make requests

```swift
// Decoded response
let user: User = try await client.request(UserEndpoint.profile)

// Fire-and-check (POST/PATCH/DELETE where you only care about success)
try await client.request(UserEndpoint.update(name: "Khanh"))

// Upload with progress
let progress = KVUploadProgressDelegate { print("Uploaded \(Int($0 * 100))%") }
try await client.request(UserEndpoint.uploadAvatar(image: imageData), progressDelegate: progress)

// Cancellation
let id = UUID().uuidString
async let result: User = client.request(UserEndpoint.profile, id: id)
client.cancelRequest(with: id)   // -> throws KVAPIClientError.taskCanceled
```

## Logging

`KVLoggingInterceptor` prints every request as a replayable cURL command and every response as pretty-printed JSON:

```
🌐 ━━━━━━━━━━ REQUEST ━━━━━━━━━━
POST https://api.example.com/api/v1/users/me
curl -v \
  -X PATCH \
  -H "Authorization: Bearer super••••••" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"Khanh\"}" \
  "https://api.example.com/api/v1/users/me"
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✅ ━━━━━━━━━━ RESPONSE [200] ━━━━━━━━━━
URL: https://api.example.com/api/v1/users/me
{
  "id" : "1",
  "name" : "Khanh"
}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

- Levels: `.none`, `.basic` (method/URL/status), `.headers`, `.body` (default)
- `Authorization`, `Cookie`, `X-API-Key`, … are redacted by default (`redactsSensitiveHeaders: false` to disable when you need a runnable cURL)
- Silent in release builds unless `logsInRelease: true`
- Custom sink: `KVLoggingInterceptor(output: { logger.debug("\($0)") })`

## Caching

Three ready-made backends, all `Sendable`-safe:

| Cache | Storage | Survives relaunch | Use case |
|---|---|---|---|
| `KVMemoryCache` | RAM, LRU | ❌ | fast session-scoped cache |
| `KVDiskCache` | caches directory | ✅ | offline tolerance |
| `KVHybridCache` | memory → disk | ✅ | default recommendation |

Per-endpoint policies:

- `.ignore` — no caching (default)
- `.cacheFirst(ttl:)` — serve a fresh cached response without touching the network
- `.networkFirst(ttl:)` — always hit the network, fall back to cache on connectivity errors
- `.refresh` — always hit the network and update the cache (feeds `cacheFirst` readers)

Cache keys are derived from method + URL + body (headers excluded), so entries survive token rotation. Clear on logout:

```swift
await client.cache?.removeAll()
```

## Token refresh

Conform to `KVTokenRefreshingInterceptorProtocol` and add the interceptor to the client. When several requests hit 401 simultaneously, `KVTokenRefreshCoordinator` runs a single refresh and the rest await it. The client retries at most **once** per request — no refresh loops.

```swift
struct TokenRefreshInterceptor: KVTokenRefreshingInterceptorProtocol {
    let tokenStore: any KVAuthTokenStoreProviding
    let coordinator = KVTokenRefreshCoordinator()

    func refreshAction(response: URLResponse?, data: Data?) async throws -> KVInterceptorAction {
        guard (response as? HTTPURLResponse)?.statusCode == 401,
              tokenStore.refreshToken != nil else { return .proceed }

        try await coordinator.refresh {
            let tokens = try await AuthAPI.refresh(token: tokenStore.refreshToken!)
            tokenStore.setAccessToken(tokens.access)
            tokenStore.setRefreshToken(tokens.refresh)
        }
        return .retryWithUpdatedToken
    }
}
```

Throw `KVAPIClientError.refreshTokenInvalid` from the refresh block to signal logout. Use `error.isNetworkConnectivityError` to avoid logging users out on flaky networks.

## Network status in SwiftUI (iOS 16 + 17)

Two observable wrappers over `KVNetworkMonitor`; pick per OS version for best performance:

```swift
struct RootView: View {
    var body: some View {
        content.overlay(alignment: .top) {
            if #available(iOS 17.0, *) {
                ModernOfflineBanner()   // @Observable — per-property tracking
            } else {
                LegacyOfflineBanner()   // ObservableObject
            }
        }
    }
}

@available(iOS 17.0, *)
struct ModernOfflineBanner: View {
    @State private var status = KVNetworkStatusModel()
    var body: some View { if !status.isConnected { OfflineLabel() } }
}

struct LegacyOfflineBanner: View {
    @StateObject private var status = KVNetworkStatusObject()
    var body: some View { if !status.isConnected { OfflineLabel() } }
}
```

## Testing your app

```swift
let mock = KVMockAPIClient()
mock.stub(path: "/users/me", with: User(id: "1", name: "Khanh"))
let viewModel = ProfileViewModel(client: mock)   // inject via KVAPIClientProtocol
```

Or stub at the transport level with `KVMockNetworkSession` to exercise the real client pipeline (interceptors, retry, cache):

```swift
let session = KVMockNetworkSession()
session.enqueue(.success((jsonData, KVMockNetworkSession.httpResponse(url: url, statusCode: 200))))
let client = KVAPIClient(session: session, interceptors: [])
```

## Error handling

All failures surface as `KVAPIClientError`:

```swift
do {
    let user: User = try await client.request(UserEndpoint.profile)
} catch let error as KVAPIClientError {
    switch error {
    case .serverMessage(let message, let statusCode):
        showAlert(message)                        // human-readable server error
    case .unauthorized, .refreshTokenInvalid:
        logout()
    case let e where e.isNetworkConnectivityError:
        showOfflineBanner()                       // do NOT logout here
    default:
        showAlert(error.localizedDescription)
    }
}
```

Server error messages are extracted automatically from common payload shapes: `{"message": …}`, `{"error": …}`, `{"detail": …}`, `{"error": {"message": …}}`, `{"errors": […]}`.

## Requirements

- iOS 16.0+ / macOS 13.0+
- Swift 5.9+
- No dependencies
