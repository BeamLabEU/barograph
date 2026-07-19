# Progress report — 2026-07-19

Status of the v0.1 vertical slice from [barograph-spec.md](barograph-spec.md) §14.

## Done

### Step 0 — project scaffold
- `mix new --sup` project (`:barograph` app, Elixir ~> 1.19, OTP 28).
- Dependencies: `exqlite` only (`ex_doc` in dev). **`jason` dropped** — spec §13 said required, but Elixir 1.18+ ships a stdlib `JSON` module, and we're on 1.19. Spec table updated to record the decision.
- Apache-2.0 LICENSE, Hex package metadata.

### Step 1 — database foundation
- `Barograph.open/2` / `close/1`, per-path `:via` registry handles; opening the same path twice returns the same handle.
- Schema per spec §5: `bg_meta`, `bg_series` (+ metric index), `bg_samples`, `bg_events` — all `STRICT`, samples/events `WITHOUT ROWID`. Also `bg_agg_meta` and `bg_agg_invalid` (§8.3/§8.4), added when step 4 landed.
- Self-describing files: `schema_version`, `time_unit`, `chunk_interval_seconds`, `created_with`. Opening a file with a foreign schema version or mismatched time unit is a checked error.
- Pragmas per §7.3: WAL, `synchronous = NORMAL`, `busy_timeout = 5000`, `foreign_keys = ON`, `auto_vacuum = INCREMENTAL` (set before first table).
- Supervision tree (§4.1, minus what doesn't exist yet): `Barograph.Supervisor` → `Registry` + `DatabaseSupervisor`; each database supervises `SeriesCache` (ETS, `{metric, labels_hash} → series_id`), `Writer`, `Refresher` under `:rest_for_one`.
- Label canonicalisation + 16-byte BLAKE2b series hash (§5.1) in `Barograph.Labels`.

### Step 2 — write path
- `Barograph.Writer`: buffers samples, commits in one transaction at `batch_size` (1000) or `batch_timeout` (100 ms); back-pressure `{:error, :overloaded}` past `max_buffer` (50 000). All three are `open/2` options. Graceful flush on terminate.
- Flush uses **one multi-row INSERT per 500 rows** — ~2.6× over per-row bind/step/reset.
- Series resolution on ETS miss: `INSERT OR IGNORE` into `bg_series` + cache populate (§7.4). Hash bound as `{:blob, _}` — exqlite binds plain binaries as TEXT, which STRICT's BLOB column rejects.
- Idempotent writes via `INSERT OR REPLACE` in arrival order (a test caught newest-first buffer order making the *oldest* write win).
- API: `write/4`, `write/5`, `write_many/2`, `flush/1`.

### Step 3 — query layer
- `Barograph.query/3` (§9.2 level 1): bucketed `avg/min/max/sum/count`, label filters via parameterized `json_extract`, inclusive-from / exclusive-to bounds, `DateTime` or integer epochs.
- `Barograph.Query.time_bucket/2` as a generated SQL fragment (§9.1).
- `Barograph.sql/2,3` (level 3, hard requirement): short-lived WAL read connection per call, rows as column-name maps, errors returned not raised. A real read pool lands with the Ecto milestone (v0.3).
- `Barograph.time_unit/1`.

### Step 4 — continuous aggregates
- `Barograph.create_continuous_aggregate/3` per §8.1: rollup table `bg_agg_<name>` with full partial state (`count`, `sum`, `min`, `max`, `first_ts/val`, `last_ts/val`, `sum_dt`, `sum_v_dt`) — count/sum, never avg (§8.2). Name validated (`^[a-z][a-z0-9_]{0,62}$`) since it becomes a table name.
- Watermark refresh (§8.3): aggregates `[watermark, now - lag)` (exclusive at the top — see review fix B1 below), upserts via `INSERT OR REPLACE`, advances watermark. One transaction per refresh; idempotent and crash-safe.
- Invalidation (§8.4): every committed batch marks dirty buckets in `bg_agg_invalid` via one `WITH batch AS (VALUES …)` statement joining `bg_series`/`bg_agg_meta`; refresh recomputes dirty buckets (delete + re-aggregate from raw) before advancing.
- `Barograph.Refresher`: internal timer fallback per §8.6 (Oban integration deferred); ticks at min `refresh_every`, no-ops cheaply when watermarks are current.
- `Barograph.refresh_aggregates/1` for manual refresh (tests, bulk imports).

## Exit criteria (spec §14, v0.1) — measured on a 64-core x86 dev box

| Criterion | Target | Measured |
|---|---|---|
| Sustained ingest, RPi 5 | 10k samples/sec | ~62–111k samples/sec (hardware- and run-dependent; 200k in 1.8–3.2 s) |
| Query a month of 1-minute data | < 100 ms | 25–35 ms (43 200 samples → 720 hourly buckets) |

Benchmarks live in `test/barograph/benchmark_test.exs`, excluded by default; run with `mix test --include benchmark`. **Not yet validated on actual RPi 5 hardware.**

## Deviations from the spec (decisions taken during implementation)

1. **jason removed** — stdlib `JSON` (see above).
2. **Watermark starts at 0** — first refresh backfills all existing data (Timescale behaviour). Spec example implies creation-time watermark; backfill is the better default and only costs once.
3. **`refresh_lag: {0, _}` allowed** — needed for tests and synchronous pipelines.
4. **`bg_agg_meta` columns renamed** — spec's `bucket_us`/`lag_us` are `bucket_width`/`lag` in the database's time unit (we support three units; `_us` would be wrong for two of them). `refresh_every` added (milliseconds) for the scheduler. Spec §8.3 now synced.
5. **First refresh may be a full scan** (consequence of 2); subsequent refreshes are watermark-bounded as specified.
6. **Invalidation is not bounded by `refresh_lag`** — spec §8.4 said older late data should not trigger recomputation; the implementation invalidates any bucket below the watermark. More correct, at the price of a dirty-bucket rescan. Spec §8.4 updated to match.

## Independent review (2026-07-19) and fixes applied

A separate agent verified this report against the code. Findings and what was done:

- **B1 (HIGH, fixed)** — a sample exactly at the refresh upper bound was permanently dropped from its aggregate bucket (boundary off-by-one: range was `(watermark, upper]`, now `[watermark, upper)`). Regression test added with a sample exactly at the boundary.
- **B2 (fixed)** — invalidation marking ran *after* the flush `COMMIT`; a crash between them left committed late data with unmarked buckets (stale forever). Marking now happens inside the flush transaction.
- **B3 (fixed)** — `time_unit` was fetched via a GenServer call to the writer on every query, coupling the read path to writer liveness during long refreshes. Now stored as the writer's Registry value; reads look it up without touching the writer.
- **B4 (fixed)** — `refresh_aggregates/1` didn't flush the write buffer first, so recently written samples were invisible to a manual refresh. It flushes first now.
- **B5 (fixed)** — `write`/`write_many`/`flush` used the 5 s default GenServer call timeout; a big flush on slow storage (RPi SD card) could crash callers spuriously. Now `:infinity`.
- **B6–B9 (deferred to v0.2, ticketed here)**: `Aggregate.create` not atomic (orphan table on crash); interpolated integers in the invalidation `VALUES` list (not exploitable — STRICT rejects non-integers earlier — but fragile); negative (pre-1970) timestamps bucket incorrectly (truncation vs floor division); `Barograph.sql/3` on a never-opened path creates a zero-byte file.

The reviewer confirmed all other report claims, including the spec deviations above.

## Second independent review (2026-07-19) and fixes applied

A third agent re-verified the report and the B1–B5 fixes above (all confirmed correct, including the B1 regression test), then found and fixed one additional issue not previously flagged:

- **B10 (HIGH, fixed)** — every place in the codebase that drained a prepared statement used the idiom `Stream.repeatedly(fn -> Exqlite.Sqlite3.step(conn, statement) end) |> Stream.take_while(&match?({:row, _}, &1))`. `step/2` is typed `:done | :busy | {:row, row} | {:error, reason}`, and `:busy`/`{:error, reason}` can surface *after* a statement has already yielded rows (lock contention, disk I/O error, malformed data mid-scan — not just on the first step). `Stream.take_while` stops at the first non-`{:row, _}` value, so a mid-scan failure was treated identically to a clean `:done` and silently returned whatever rows had been collected so far as if the query had succeeded — no error, no indication of truncation. Confirmed reproducible: `json_extract` on a row with malformed JSON makes a real SQLite statement return `{:row, _}, {:row, _}, {:error, "malformed JSON"}`, and the old code silently returned the first two rows as a success.

  Affected five sites: `Barograph.SQL.query/3` (the spec's "hard requirement" level-3 API — its own `"returns errors instead of raising"` test only covered a `prepare`-time failure, not a step-time one), `Barograph.Schema.read_meta/1`, `Barograph.Aggregate.definitions/1`, `Barograph.Aggregate.recompute_invalid_buckets/2`, `Barograph.Writer.warm_series_cache/2`.

  Fix: new `Barograph.Rows` module with `fetch_all/2` (returns `{:ok, rows} | {:error, reason}`, for call sites that already thread `Result` tuples — `sql.ex`, `schema.ex`) and `fetch_all!/2` (raises on failure, for call sites that use the codebase's existing crash-on-unexpected-DB-error convention — `aggregate.ex`, `writer.ex`'s cache warm). All five sites now use one of the two instead of the bare `Stream.take_while` idiom. Regression tests in `test/barograph/rows_test.exs` force a genuine mid-scan SQLite error via malformed JSON and assert both the module (`fetch_all/2`, `fetch_all!/2`) and the public API (`Barograph.sql/3`) now report the failure instead of returning partial rows.

The reviewer confirmed all other code and report claims from the first review round.

## Known limitations (v0.1, documented in code)

- `sum_dt`/`sum_v_dt` (time-weighted average state) count intervals within the refreshed window only; the interval spanning a window boundary is not credited.
- Real-time aggregate view (§8.5) not implemented — aggregate tables contain finalised buckets only. Query them via `Barograph.sql/3`.
- Reads use one ephemeral connection per query; no read pool yet (v0.3, with Ecto).
- No chunking yet (single `bg_samples` table); the union-view machinery arrives with retention in v0.2.
- `bg_events` table exists but there is no events API yet (v0.3).

## Remaining for v0.1

- Step 5: `Barograph.Barogram.svg/2` basic line chart.

## Test status

`mix test`: 47 tests, 0 failures (2 excluded: benchmarks). Files: `test/barograph_test.exs`, `test/barograph/{labels,writer,query,aggregate,rows}_test.exs`, `test/barograph/benchmark_test.exs`.
