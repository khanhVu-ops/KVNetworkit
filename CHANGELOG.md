# Changelog

All notable changes to KVNetworkit. This project follows [Semantic Versioning](https://semver.org).

## 2.1.0

Fixes around cancellation, retries, error bodies and resource lifetime, plus Swift 6
language-mode support. Source compatible with 2.0; the behavior changes below are deliberate.

### Behavior changes

- **Only idempotent methods are retried by default.** `KVRetryPolicy` gained `retryableMethods`
  (default `KVRetryPolicy.idempotentMethods`: GET, HEAD, PUT, DELETE, OPTIONS, TRACE). A `POST`
  or `PATCH` — including a streamed chat request — is no longer replayed after a 5xx or a dropped
  connection, where the server may already have acted on it. Opt back in per policy
  (`KVRetryPolicy(maxRetries: 2, retryableMethods: [.post])`) or per endpoint (below).
- **Cancelling the calling task cancels the request.** Requests used to run in an unstructured
  `Task` that ignored the caller, so a SwiftUI `.task` going away left the request running. The
  `URLSession` task is now cancelled and the call throws `.taskCanceled`. `cancelRequest(with:)`
  on a real `URLSession` also throws `.taskCanceled` now, where it used to surface as
  `.networkError(URLError(.cancelled))`.
- **Sensitive headers are fully redacted** as `••••••`. Previously the first 12 characters were
  kept (`Bearer eyJhbG••••••`). Headers whose name contains `key`, `token` or `secret` are now
  redacted too.
- A stream's `try await` throws `.taskCanceled` (not a bare `CancellationError`) when cancelled
  while connecting.
- `stream(_:as:decoder:framing:id:)` decodes each payload when the consumer asks for it rather
  than ahead of time in a background task. Values and ordering are unchanged.

### Added

- `KVAPIEndpointProtocol.retryPolicy` (default `nil`: the client's policy) — per-endpoint override,
  e.g. `.never` for a payment, or a policy that opts a safe `POST` in.
- `Retry-After` is honoured on retried responses (delta-seconds or HTTP date), capped by the
  policy's `maxDelay`. New `KVRetryPolicy.delay(forAttempt:retryAfter:)` and `shouldRetry(method:)`.
- `KVHTTPErrorResponse` — status code, headers, URL and the **raw body** of a non-2xx response,
  with `decode(_:)`, `text` and the extracted `message`. Opt in with
  `KVAPIClient(errorResponseMapper:)`: return the response itself to throw it, your own error type,
  or `nil` for the default `KVAPIClientError`. Applies to streams too. Existing `switch`/`catch`
  code is unaffected unless you set a mapper.
- `KVNetworkSession(streamResourceTimeout:)` — streams run on a second session whose resource
  timeout defaults to 7 days, so SSE streams are no longer killed after the 300 s
  `resourceTimeout`. `requestTimeout` still applies as the idle timeout.
- `KVLoggingInterceptor(sensitiveHeaderKeywords:)` — substring matching for header redaction
  (default `["key", "token", "secret"]`).
- `KVTaskRegistration`, `KVTaskManagerProtocol.register(_:task:)` and `complete(_:)` — atomic
  check-and-register, and completion that only removes its own entry. Both have default
  implementations, so custom conformers keep compiling (with 2.0's non-atomic behavior).

### Fixed

- Request ids: the "already in progress" check and the registration were separate steps, and a
  finishing request removed whatever was tracked under its id — including a newer request that
  had reused it, which then could no longer be cancelled. Streams also claimed their id only after
  connecting, so `cancelRequest(with:)` did nothing while a stream was connecting.
- Progress-tracked uploads created a `URLSession` per upload and never invalidated it. Sessions
  created by `KVNetworkSession` are now invalidated (`finishTasksAndInvalidate`) when it is
  released, which the client does as soon as the upload finishes.
- A `content-type` header declared in lowercase no longer gets a second, derived `Content-Type`.
- `KVMockAPIClient.stubbedError` is now lock-protected like the rest of the mock.
- Swift 6 language mode: the package now compiles with `-swift-version 6` (tools version stays 5.9).
  Only `Data` crosses task boundaries, so decoded types still don't need to be `Sendable`.
- README: `.unauthorized` is not thrown for a plain 401 — that is `.serverMessage`/`.statusCode`
  with status 401. The docs now match on `error.statusCode == 401`; the runtime is unchanged.

### Notes

- `KVAPIEndpointProtocol` is deliberately **not** `Sendable`: endpoints often carry payloads that
  aren't (`UIImage`, `[String: Any]`), and the client now only captures `Sendable` values derived
  from them (`URLRequest`, policies).
- An endpoint type that already declares a `retryPolicy` property of another type will now clash
  with the new requirement; rename it.
- Non-JSON error bodies (e.g. a `text/plain` traceback on 500) were already handled — they become
  `.statusCode(_:)` — and now have tests.

## 2.0.0

Streaming responses: server-sent events, NDJSON and raw chunks, on the same pipeline as
regular requests.

### Breaking

- `KVAPIClientProtocol` gained one requirement: `stream(_:accept:id:)`. Types that conform to
  the protocol themselves (usually hand-written test doubles) must implement it — or switch to
  the bundled `KVMockAPIClient`, which already does. Everything else is source compatible;
  `KVAPIClient` users are unaffected.

### Added

- `KVAPIClient.stream(_:accept:id:)` — the response body as `KVDataStream`
  (`AsyncThrowingStream<Data, any Error>`), returned once the response head has been validated.
- `streamEvents(_:framing:id:)` → parsed `KVServerSentEvent` values, and
  `stream(_:as:decoder:framing:id:)` → decoded payloads with the `[DONE]` sentinel skipped.
- `streamLines(_:id:)` → whole text lines, for inspecting an unfamiliar stream format.
- `KVStreamFraming`: `.serverSentEvents` (spec, blank-line delimited),
  `.serverSentEventsPerLine` (one payload per `data:` line), `.jsonLines` (NDJSON). Sets a
  matching `Accept` header unless the endpoint declares one.
- `KVStreamInterceptorProtocol` — observe or transform a streaming body:
  `streamDidOpen(id:response:)`, `stream(id:didReceive:)`, `streamDidClose(id:statistics:error:)`,
  all with no-op defaults. Reported through `KVStreamStatistics` (chunks, bytes, duration).
- `KVLoggingInterceptor` logs streams too, with a `streamBodyLogging` option:
  `.aggregated` (default — whole body once on close, capped by `maxBodyLogLength`),
  `.perChunk`, `.none`.
- `KVSSEParser` and `KVLineAccumulator` — incremental parsing usable standalone. Handles events
  split across chunks, `\n` / `\r\n` / `\r`, multi-byte characters cut in half, a leading BOM,
  comments, multi-line `data:`, and a trailing event with no final blank line.
- `KVNetworkSessionProtocol.bytes(for:)`, with a buffering default implementation so existing
  conformers keep working. `KVNetworkSession` implements it over a per-task
  `URLSessionDataDelegate`, which delivers real network chunks.
- Test support: `KVMockNetworkSession.enqueueStream(chunks:response:terminatingError:)` and
  `enqueueStream(error:)`, helpers `sseChunks(_:)` and `chunks(of:size:)` for re-chunking a
  payload at arbitrary boundaries, plus `KVMockAPIClient.stub(path:streamChunks:)` /
  `stub(path:streamPayloads:)`.

### Behavior notes

- Streams reuse request interceptors, retry with backoff, and one-shot token refresh. Retry
  covers connection setup and the response head only: once chunks have been delivered a failure
  is surfaced rather than silently restarting.
- A non-2xx status reads the error body and throws `.serverMessage(_:_:)` from the initiating
  `try await`, before the first chunk is consumed.
- `cancelRequest(with:)` and `cancelAllRequests()` end streams with `.taskCanceled`; dropping the
  stream cancels the underlying task.
- The response cache is bypassed for streams.
- `streamDidClose` runs before the consumer's `for try await` loop ends, so logging and metrics
  are never late.

## 1.0.0

Initial release: endpoint-driven requests, interceptor pipeline, cURL + response logging,
memory/disk/hybrid caching with TTL policies, retry with exponential backoff and jitter, token
refresh, network monitoring, multipart upload with progress, cancellation by id, and test doubles.
