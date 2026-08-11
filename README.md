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
- 📡 **Streaming responses** — server-sent events, NDJSON and raw chunks as `AsyncThrowingStream`, for LLM/chat token streams
- ❌ **Cancellation** — cancel individual requests by id, or all at once
- 🧪 **Test support** — mock client, session and interceptor ship with the package

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/<your-org>/KVNetworkit.git", from: "2.0.0")
]
```

Upgrading from 1.x? See [CHANGELOG.md](CHANGELOG.md) — one protocol requirement was added, and it
only affects hand-written `KVAPIClientProtocol` conformers.

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

## Streaming (SSE / NDJSON)

Chat and LLM endpoints answer with a long-lived body instead of one payload. `stream…` methods return
as soon as the response head has been validated, then deliver the body as it arrives:

```swift
struct ChatDelta: Decodable {
    let type: String        // "chunk" | "done" | "error"
    let content: String?
}

for try await delta in try await client.stream(ChatEndpoint.interact(text), as: ChatDelta.self) {
    guard delta.type == "chunk", let content = delta.content else { continue }
    message.text += content        // render token by token
}
```

Three levels of API, pick by how much control you need:

```swift
// 1. Decoded values, one per event payload ([DONE] is skipped for you)
try await client.stream(endpoint, as: ChatDelta.self)          // AsyncThrowingStream<ChatDelta, Error>

// 2. Parsed `KVServerSentEvent`s — when you need `event:` / `id:`, or want to ignore
//    payload shapes you don't care about
for try await event in try await client.streamEvents(endpoint) {
    guard !event.isDoneSentinel else { break }
    switch event.event {
    case "message_delta": append(try event.decode(Delta.self).text)
    default: continue
    }
}

// 3. Raw lines or raw chunks — for unfamiliar formats and non-text bodies
try await client.streamLines(endpoint)                          // AsyncThrowingStream<String, Error>
try await client.stream(endpoint)                               // KVDataStream, i.e.
                                                                // AsyncThrowingStream<Data, Error>
```

### Framing

Backends disagree on how events are delimited, so say which one you are talking to:

| `KVStreamFraming` | Body looks like | `Accept` sent |
| --- | --- | --- |
| `.serverSentEvents` (default) | `data: {…}\n\n` — blank line ends each event, multiple `data:` lines are joined | `text/event-stream` |
| `.serverSentEventsPerLine` | `data: {…}\n` — one payload per line, **no** blank separator | `text/event-stream` |
| `.jsonLines` | `{…}\n{…}\n` — no `data:` prefix | `application/x-ndjson` |

```swift
try await client.streamEvents(endpoint, framing: .serverSentEventsPerLine)
```

The `Accept` header is only added when the endpoint does not declare one. Start with
`streamLines(_:)` when you are unsure what a server actually sends.

### What you get for free

- **Interceptors** run on the request as usual — auth headers, cURL logging, connectivity checks
- **Retry** covers connection setup and the response head. Once chunks start flowing a failure is
  surfaced instead of silently restarting, because the caller already consumed part of the output
- **Token refresh** works: a 401 is refreshed and retried once, exactly like a normal request
- **Error bodies are read**, so a failed stream throws `.serverMessage("Quota exceeded", 429)` from the
  `try await` — before your `for` loop ever runs — instead of a bare status code
- **Cancellation** by id: `client.cancelRequest(with: "chat")` ends the stream with `.taskCanceled`,
  and dropping the stream cancels the underlying task
- **Chunk boundaries are handled**: events split across TCP chunks, `\r\n` vs `\n`, multi-byte
  characters cut in half, and a trailing event with no final blank line are all reassembled correctly

The cache is bypassed for streams — a partial response is not a cacheable one.

Parsing is available standalone when you drive a stream yourself: `KVSSEParser` (`Data` → events) and
`KVLineAccumulator` (`Data` → whole lines).

### Intercepting the stream body

`intercept(response:data:)` is called with the head and `nil` data for a stream — the body has not
arrived yet. To see the chunks, conform to `KVStreamInterceptorProtocol`; `KVAPIClient` picks
conformers out of its regular interceptor list, so one instance can serve both worlds:

```swift
struct StreamMetricsInterceptor: KVStreamInterceptorProtocol {
    func streamDidOpen(id: String, response: URLResponse) async { … }

    // Return replacement data to transform, nil to pass through. Throwing fails the stream.
    func stream(id: String, didReceive chunk: Data) async throws -> Data? { nil }

    func streamDidClose(id: String, statistics: KVStreamStatistics, error: (any Error)?) async {
        analytics.record(
            chunks: statistics.chunkCount,
            bytes: statistics.byteCount,     // counted after transforms, i.e. what the caller read
            seconds: statistics.duration,
            failed: error != nil
        )
    }
}
```

All three methods have no-op defaults — implement only what you need. `id` is the request id you
passed to `stream(_:id:)`, which is what makes per-stream state safe when one interceptor instance
serves several concurrent streams. Interceptors run in list order, and `streamDidClose` fires
*before* your `for try await` loop ends, so logs and metrics are never late.

`KVLoggingInterceptor` already implements it, so streams are logged like everything else:

```
📡 ━━━━━━━━━━ STREAM OPEN [200] ━━━━━━━━━━
URL: https://api.example.com/chat/stream
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🏁 ━━━━━━━━━━ STREAM CLOSED [12 chunks · 486 B · 1.83s] ━━━━━━━━━━
data: {"type":"chunk","content":"xin "}
data: {"type":"chunk","content":"chào"}
data: [DONE]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Pick how the body is logged with `streamBodyLogging` (applies at `.body` level only):

| Value | Behavior |
| --- | --- |
| `.aggregated` (default) | Buffer the chunks, print the whole body once on close — closest to how a normal response is logged. Buffer capped by `maxBodyLogLength`. |
| `.perChunk` | Print every chunk as it lands. Noisy on token streams, but the way to see how a server really frames its events. |
| `.none` | Open/close lines only. Use for infinite streams. |

```swift
KVLoggingInterceptor(level: .body, streamBodyLogging: .perChunk)
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

Streams are stubbable the same way, at either level:

```swift
mock.stub(path: "/chat", streamPayloads: [#"{"type":"chunk","content":"hi"}"#, "[DONE]"])

session.enqueueStream(
    chunks: KVMockNetworkSession.sseChunks(["hi", "[DONE]"]),
    response: KVMockNetworkSession.httpResponse(url: url, statusCode: 200),
    terminatingError: nil            // set one to simulate a dropped connection mid-stream
)

// Re-chunk a payload to prove your parsing survives arbitrary network boundaries
session.enqueueStream(chunks: KVMockNetworkSession.chunks(of: body, size: 1), response: ok)
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

## Example app

`KVNetworkitExample/` is a runnable SwiftUI app wired to the local package:

| Tab | Shows |
| --- | --- |
| **Posts** | Decoded GET + `networkFirst` / `cacheFirst` caching, pull-to-refresh |
| **Create** | POST with a JSON body and server-message error handling |
| **Stream** | Live SSE against Wikimedia EventStreams — events rendered as they arrive, Stop cancels by id, and the footer stats come from a `KVStreamInterceptorProtocol` conformer |
| **Status** | `KVNetworkMonitor` connectivity state |

The Stream tab is the shortest read for the streaming API — see
`Features/Streaming/LiveStreamViewModel.swift` (about 15 lines of actual streaming code) and
`Networking/StreamStatsInterceptor.swift` for the interceptor side.

## Requirements

- iOS 16.0+ / macOS 13.0+
- Swift 5.9+
- No dependencies
