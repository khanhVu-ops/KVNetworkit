# Changelog

All notable changes to KVNetworkit. This project follows [Semantic Versioning](https://semver.org).

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
