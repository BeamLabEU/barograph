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
- Watermark refresh (§8.3): aggregates `(watermark, now - lag]`, upserts via `INSERT OR REPLACE`, advances watermark. One transaction per refresh; idempotent and crash-safe.
- Invalidation (§8.4): every committed batch marks dirty buckets in `bg_agg_invalid` via one `WITH batch AS (VALUES …)` statement joining `bg_series`/`bg_agg_meta`; refresh recomputes dirty buckets (delete + re-aggregate from raw) before advancing.
- `Barograph.Refresher`: internal timer fallback per §8.6 (Oban integration deferred); ticks at min `refresh_every`, no-ops cheaply when watermarks are current.
- `Barograph.refresh_aggregates/1` for manual refresh (tests, bulk imports).

## Exit criteria (spec §14, v0.1) — measured on a 64-core x86 dev box

| Criterion | Target | Measured |
|---|---|---|
| Sustained ingest, RPi 5 | 10k samples/sec | ~106–111k samples/sec (200k in ~1.8 s) |
| Query a month of 1-minute data | < 100 ms | 35 ms (43 200 samples → 720 hourly buckets) |

Benchmarks live in `test/barograph/benchmark_test.exs`, excluded by default; run with `mix test --include benchmark`. **Not yet validated on actual RPi 5 hardware.**

## Deviations from the spec (decisions taken during implementation)

1. **jason removed** — stdlib `JSON` (see above).
2. **Watermark starts at 0** — first refresh backfills all existing data (Timescale behaviour). Spec example implies creation-time watermark; backfill is the better default and only costs once.
3. **`refresh_lag: {0, _}` allowed** — needed for tests and synchronous pipelines.
4. **`bg_agg_meta` columns renamed** — spec's `bucket_us`/`lag_us` are `bucket_width`/`lag` in the database's time unit (we support three units; `_us` would be wrong for two of them). `refresh_every` added (milliseconds) for the scheduler.
5. **First refresh may be a full scan** (consequence of 2); subsequent refreshes are watermark-bounded as specified.

## Known limitations (v0.1, documented in code)

- `sum_dt`/`sum_v_dt` (time-weighted average state) count intervals within the refreshed window only; the interval spanning a window boundary is not credited.
- Real-time aggregate view (§8.5) not implemented — aggregate tables contain finalised buckets only. Query them via `Barograph.sql/3`.
- Reads use one ephemeral connection per query; no read pool yet (v0.3, with Ecto).
- No chunking yet (single `bg_samples` table); the union-view machinery arrives with retention in v0.2.
- `bg_events` table exists but there is no events API yet (v0.3).

## Remaining for v0.1

- Step 5: `Barograph.Barogram.svg/2` basic line chart.

## Test status

`mix test`: 42 tests, 0 failures (2 excluded: benchmarks). Files: `test/barograph_test.exs`, `test/barograph/{labels,writer,query,aggregate}_test.exs`, `test/barograph/benchmark_test.exs`.
