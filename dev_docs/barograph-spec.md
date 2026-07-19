# Barograph — Technical Specification

**Time-series and event analytics for Elixir, stored in SQLite.**
One file. No server. Full SQL.

| | |
|---|---|
| **Status** | Draft v0.1 |
| **Package** | `barograph` (Hex) |
| **Namespace** | `Barograph` |
| **Repository** | `BeamLabEU/barograph` |
| **Site** | barographdb.com |
| **License** | Apache-2.0 (intentionally: no TSL-style split) |
| **Author** | Dmitri / BeamLabEU |

---

## 1. Motivation

In 1844 a barograph recorded atmospheric pressure by dragging a pen across paper wrapped around a slowly rotating drum. One revolution per week. When the drum came full circle, the pen wrote over the oldest trace.

That is a round-robin database, and it predates the computer by a century.

### 1.1 The gap

The observability ecosystem has bifurcated. At one end sit server-class systems — Prometheus, TimescaleDB, ClickHouse, VictoriaMetrics — all excellent, all requiring a daemon, a port, a configuration file, and an operational story. At the other end sits RRDtool, which is genuinely alive (1.10.3 shipped May 2026) and still unmatched for fixed-footprint local storage, but which predates the label model and cannot answer dimensional queries.

Between them there is very little. Specifically, there is nothing that offers:

- Embedded operation with **zero additional processes**
- **Dimensional (labelled) series**, not one-datasource-per-column
- **Real SQL** access to the stored data
- A storage artifact that is **a single file you can copy, email, or ship inside a firmware image**
- Permissive licensing with **no feature gating**

Elixir has no time-series library at all. Projects reach for TimescaleDB (requires Postgres, and its best features are TSL-licensed), InfluxDB via `instream` (requires a server), or they hand-roll rollup tables and regret it.

### 1.2 Why now, why Elixir

Two of the hard parts of a time-series engine map unusually well onto the BEAM:

- **Serialised writes.** SQLite permits one writer. On most runtimes this is a problem to be engineered around. On the BEAM, "funnel all writes through one process that batches and commits transactionally" is the natural shape of the solution, not a workaround.
- **Scheduled background refresh.** Continuous-aggregate maintenance is a periodic idempotent job. Oban already does this well, and most Elixir projects already run it.

### 1.3 Non-motivations

This is not an attempt to beat TimescaleDB or ClickHouse on a 16-core server. It will lose, and that is fine. Barograph targets the deployments those systems cannot reach.

---

## 2. Goals and non-goals

### 2.1 Goals

1. Store labelled time-series and event data in a single SQLite database file.
2. Provide Timescale-shaped ergonomics: hypertables, continuous aggregates, retention policies, time-bucketed queries.
3. Keep stored data **queryable by hand with plain SQL**. A user with `sqlite3` and no knowledge of this library should be able to answer questions about their data.
4. Run inside a Nerves firmware, a single-binary release, or a developer laptop with no additional installation.
5. Render charts without a JavaScript charting library, an image encoder, or a browser.
6. Accept data from existing collection agents without writing custom exporters.
7. Be usable standalone — no Phoenix dependency, no `phoenix_kit` dependency.

### 2.2 Non-goals

| Not doing | Why |
|---|---|
| Distributed / clustered storage | Single-file is the product. Clustering contradicts it. |
| High-cardinality label sets (>100k active series per DB) | SQLite index behaviour degrades; out of scope. |
| PromQL / Flux / a custom query language | SQL is the differentiator. Adding a DSL undermines it. |
| Alerting and notification routing | Composable concern. Users have Oban and their own logic. |
| Long-term retention at petabyte scale | Use ClickHouse. |
| Replacing Grafana | Barograph renders charts; it is not a dashboarding product. |
| Columnar compression (v1) | See §7.6 — deferred deliberately. |

### 2.3 Explicit non-goal: no feature gating

Every feature in Barograph is Apache-2.0. There is no community edition, no source-available tier, no "advanced features" carve-out. This is a positioning decision as much as a licensing one — it is the direct answer to TimescaleDB's TSL split.

---

## 3. Prior art

| System | Storage | Labels | SQL | Embedded | Licence |
|---|---|---|---|---|---|
| RRDtool | Fixed-size ring file | No | No | Yes | GPL |
| Graphite / Whisper | Fixed-size file per series | Tags (bolted on) | No | No | Apache-2.0 |
| Prometheus TSDB | Custom block format | Yes | No (PromQL) | No | Apache-2.0 |
| TimescaleDB | Postgres extension | Yes (columns) | Yes | No | Apache-2.0 / TSL |
| InfluxDB | TSM / IOx | Yes | Partial | No | MIT / commercial |
| **Barograph** | **SQLite** | **Yes** | **Yes** | **Yes** | **Apache-2.0** |

Ideas taken deliberately:

- **From RRDtool**: fixed-footprint thinking, hierarchical rollups, the idea that a chart is a first-class output rather than a client concern.
- **From TimescaleDB**: hypertable-as-view-over-chunks, continuous aggregates with a watermark, partial aggregate state, retention as partition drop.
- **From Prometheus**: series identity separated from samples, labels hashed to an integer series ID.

Ideas deliberately rejected:

- RRDtool's destructive downsampling. Rollups in Barograph are additive; raw data is dropped by explicit policy, never silently overwritten.
- RRDtool's one-datasource-per-column model. This is the specific limitation that ended its relevance.
- Prometheus's pull model. Barograph is push-based; pull requires service discovery, which requires infrastructure.

---

## 4. Architecture overview

```
   agents                  ingest              engine              output
┌──────────────┐      ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│ collectd     │      │              │   │  Writer      │   │  Query API   │
│ Telegraf     │─────▶│  Graphite    │──▶│  (1 proc /   │──▶│  (Ecto or    │
│ Vector       │ TCP  │  line proto  │   │   database)  │   │   raw SQL)   │
│ Alloy        │      │  listener    │   │              │   │              │
│ statsd       │      └──────────────┘   │  batches +   │   ├──────────────┤
└──────────────┘                         │  commits     │   │  Barogram    │
                      ┌──────────────┐   │              │   │  (SVG)       │
   application ──────▶│  Native API  │──▶│              │   └──────────────┘
                      │  write/2     │   └──────┬───────┘
                      └──────────────┘          │
                                         ┌──────▼───────┐   ┌──────────────┐
                                         │   SQLite     │◀──│  Rollup jobs │
                                         │   (WAL)      │   │  (Oban)      │
                                         └──────────────┘   └──────────────┘
```

### 4.1 Supervision tree

```
Barograph.Supervisor
├── Barograph.Registry              (via_tuple lookup per database)
├── Barograph.DatabaseSupervisor    (DynamicSupervisor, one child per open DB)
│   └── Barograph.Database
│       ├── Barograph.Writer        (owns the single write connection)
│       ├── Barograph.ReadPool      (db_connection pool, N readers)
│       └── Barograph.SeriesCache   (ETS: labels_hash -> series_id)
└── Barograph.Ingest.Supervisor     (optional, only if listeners configured)
    └── Barograph.Ingest.Graphite   (ThousandIsland)
```

Multiple databases may be open simultaneously — e.g. one per tenant, or one per device on an edge gateway.

---

## 5. Data model

### 5.1 Series identity

Series identity is separated from sample data, following Prometheus rather than RRDtool.

```sql
CREATE TABLE bg_series (
  id           INTEGER PRIMARY KEY,
  metric       TEXT NOT NULL,
  labels_hash  BLOB NOT NULL,     -- 16-byte hash of canonicalised labels
  labels       TEXT NOT NULL,     -- JSON object, for querying + display
  created_at   INTEGER NOT NULL,
  UNIQUE (metric, labels_hash)
) STRICT;

CREATE INDEX bg_series_metric ON bg_series (metric);
```

Label canonicalisation: keys sorted, values UTF-8, joined with `\x00` separators, hashed with `:crypto.hash(:blake2b, ...)` truncated to 16 bytes. Deterministic across nodes and restarts.

The `labels` JSON column exists so that hand-written SQL can filter with SQLite's `json_extract`. It is redundant with the hash and that is intentional — the hash is for the write path, the JSON is for humans.

### 5.2 Samples

```sql
CREATE TABLE bg_samples (
  series_id  INTEGER NOT NULL,
  ts         INTEGER NOT NULL,   -- epoch, unit declared at DB creation
  value      REAL NOT NULL,
  PRIMARY KEY (series_id, ts)
) STRICT, WITHOUT ROWID;
```

Design notes:

- `WITHOUT ROWID` — the primary key *is* the storage order. Avoids a second B-tree and makes range scans on `(series_id, ts)` sequential.
- Integer epochs, not ISO strings. Storage, comparison, and bucketing arithmetic are all cheaper, and delta encoding remains possible later.
- `STRICT` (SQLite ≥ 3.37) so a stray string cannot silently land in a `REAL` column.
- Time unit (`:second`, `:millisecond`, `:microsecond`) is fixed at database creation and recorded in metadata. Mixing units in one database is not supported.

### 5.3 Events

Event data — irregular, payload-bearing records rather than scalar samples — uses a parallel table:

```sql
CREATE TABLE bg_events (
  series_id  INTEGER NOT NULL,
  ts         INTEGER NOT NULL,
  payload    TEXT NOT NULL,      -- JSON
  PRIMARY KEY (series_id, ts)
) STRICT, WITHOUT ROWID;
```

Events participate in retention and chunking but not in numeric rollups. They exist so that "the forklift threw fault code 0x2A" and "engine temp was 94°C" live in the same file and can be joined in one query. This is the single largest practical advantage over both RRDtool and Prometheus.

### 5.4 Metadata

```sql
CREATE TABLE bg_meta (
  key    TEXT PRIMARY KEY,
  value  TEXT NOT NULL
) STRICT;
```

Holds schema version, time unit, chunk interval, and the library version that created the file. Any Barograph file is self-describing; opening a file written by a different version is a checked operation, not a hope.

---

## 6. Chunking

SQLite has neither partitioning nor table inheritance. Two backends are specified.

### 6.1 Backend A: `:tables` (default)

Chunks are separate tables within one database file, named `bg_samples_<epoch_start>`. A view unions them:

```sql
CREATE VIEW bg_samples AS
  SELECT * FROM bg_samples_1750000000
  UNION ALL
  SELECT * FROM bg_samples_1750086400;
```

The view is regenerated whenever a chunk is created or dropped.

- **Pro**: one file; raw SQL sees a single logical table; no attach limits.
- **Con**: `DROP TABLE` returns pages to the freelist but does not shrink the file. Requires `PRAGMA auto_vacuum = INCREMENTAL` plus a periodic `incremental_vacuum` job.
- **Con**: very large chunk counts make the view definition unwieldy. Mitigated by choosing a sensible chunk interval (default: 7 days).

### 6.2 Backend B: `:files`

Each chunk is its own SQLite file, `ATTACH`ed on demand.

- **Pro**: retention is `File.rm/1` — a genuine unlink, matching Timescale's cheap chunk drop. Space is reclaimed immediately.
- **Pro**: chunks can be moved, archived, or shipped individually.
- **Con**: `SQLITE_MAX_ATTACHED` defaults to 10 (compile-time maximum 125). The library must plan which chunks a query touches and attach only those.
- **Con**: **this breaks the raw-SQL-access goal.** A user cannot open the file and query across time without the library's help.

**Recommendation**: ship `:tables` as default. Offer `:files` for edge devices where reclaiming disk matters more than ad-hoc SQL. Document the tradeoff prominently — it is the sharpest fork in the design.

### 6.3 Chunk sizing

Default interval: 7 days. Rationale: keeps the union view small over multi-year retention, and keeps the hot chunk's index small enough to stay in page cache on constrained hardware. Configurable at hypertable creation.

---

## 7. Write path

The single most important performance decision in the library.

### 7.1 Single writer

One `Barograph.Writer` GenServer per database owns the sole write connection. All writes — API calls, ingest listeners, rollup refreshes — funnel through it. Readers use a separate `db_connection` pool and never contend, because WAL mode allows concurrent readers alongside one writer.

### 7.2 Batching

The writer accumulates incoming samples and commits on whichever comes first:

- `batch_size` samples buffered (default 1000)
- `batch_timeout` milliseconds elapsed (default 100)

Each flush is one transaction using one prepared, reused statement.

This is not a micro-optimisation. Per-row autocommit yields a few hundred inserts/second because each commit is an fsync. Batched in a transaction, tens of thousands. Two orders of magnitude, from one design choice.

Back-pressure: if the buffer exceeds `max_buffer` (default 50 000), `write/2` returns `{:error, :overloaded}` rather than growing without bound. Callers decide whether to drop or retry. Silent unbounded buffering is how embedded systems OOM.

### 7.3 Pragmas

```
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA busy_timeout = 5000;
PRAGMA foreign_keys = ON;
PRAGMA auto_vacuum = INCREMENTAL;   -- :tables backend only
```

`synchronous = NORMAL` under WAL risks losing the last transaction on power loss, not corruption. For metrics this is the right trade. Configurable to `FULL` for callers who disagree.

### 7.4 Series resolution

The write path must never join to resolve a series. `Barograph.SeriesCache` holds `labels_hash → series_id` in ETS with `read_concurrency: true`. On miss, the writer inserts the series row and populates the cache. Cache is warmed from `bg_series` on database open.

### 7.5 Late and out-of-order data

Accepted without special handling — `INSERT OR REPLACE` on the `(series_id, ts)` primary key makes writes idempotent. Samples landing in an already-rolled-up bucket mark that bucket dirty; the next refresh recomputes it (§8.4).

Samples older than the retention horizon are rejected with `{:error, :too_old}`.

### 7.6 Compression: deferred

Timescale's Hypercore collapses ~1000 rows into one row of arrays, then applies delta-of-delta, simple-8b, run-length, and XOR encoding by column type. Reported ratios reach 90–98%; real-world reports cluster at 10–20×.

The genuine benefit is **not** disk saving — it is query speed, from columnar locality plus per-batch min/max metadata acting as a zone map that lets the planner skip whole batches.

Barograph defers this to post-1.0, because:

1. Decompressing at query time requires a table-valued function, which requires a C extension. Compressed chunks would become **opaque to raw SQL**, destroying the project's main differentiator.
2. At target data volumes disk is not the constraint.
3. Most of the win is available without it: keep raw data for days, rollups forever.

If revisited, the shape would be BLOB-packed batches with `min_ts`/`max_ts` sibling columns for batch skipping, and `:zlib` (Erlang stdlib, no NIF) for the bytes — accepting that those chunks are library-only.

---

## 8. Continuous aggregates

The highest-value feature and the one that most justifies the library's existence.

### 8.1 Definition

```elixir
Barograph.create_continuous_aggregate(db, "cpu_1h",
  from: "cpu_usage",
  bucket: {1, :hour},
  refresh_lag: {5, :minute},
  refresh_every: {1, :minute}
)
```

Creates:

```sql
CREATE TABLE bg_agg_cpu_1h (
  bucket     INTEGER NOT NULL,
  series_id  INTEGER NOT NULL,
  count      INTEGER NOT NULL,
  sum        REAL NOT NULL,
  min        REAL NOT NULL,
  max        REAL NOT NULL,
  first_ts   INTEGER NOT NULL,
  first_val  REAL NOT NULL,
  last_ts    INTEGER NOT NULL,
  last_val   REAL NOT NULL,
  sum_dt     REAL NOT NULL,   -- for time-weighted average
  sum_v_dt   REAL NOT NULL,
  PRIMARY KEY (series_id, bucket)
) STRICT, WITHOUT ROWID;
```

### 8.2 Partial aggregate state, not final values

Store `count` and `sum`, never `avg`. This is the rule that makes everything else work:

- Hierarchical rollups compose. `1m → 1h → 1d` without ever rescanning raw data.
- Re-aggregation across arbitrary windows stays correct.
- Time-weighted averages remain computable (`sum_v_dt / sum_dt`).

Getting this wrong is the most common failure in hand-rolled rollup systems.

### 8.3 Watermark

```sql
CREATE TABLE bg_agg_meta (
  name       TEXT PRIMARY KEY,
  source     TEXT NOT NULL,
  bucket_us  INTEGER NOT NULL,
  watermark  INTEGER NOT NULL,   -- highest finalised bucket
  lag_us     INTEGER NOT NULL
) STRICT;
```

The refresh job aggregates only `(watermark, now - lag]` and upserts. Idempotent, crash-safe, and cheap — the cost is proportional to new data, not total data.

### 8.4 Invalidation

Late-arriving data below the watermark is recorded in `bg_agg_invalid (name, bucket)`. The refresh job recomputes dirty buckets before advancing. Bounded by `refresh_lag`; samples older than the invalidation horizon are accepted into raw storage but do not trigger recomputation, and this is documented as a known limitation.

### 8.5 Real-time view

Queries against an aggregate return finalised buckets from the rollup table `UNION ALL` live aggregation over raw data above the watermark. Users see current data without waiting for a refresh, exactly as Timescale's real-time aggregates behave.

Disableable per-aggregate for callers who prefer stable results over fresh ones.

### 8.6 Scheduling

Refresh runs as an Oban job when Oban is available, and falls back to an internal `:timer`-driven GenServer when it is not. Oban must remain an optional dependency — Nerves targets should not be forced to carry it.

---

## 9. Query layer

### 9.1 Hyperfunctions as generated SQL

SQLite ≥ 3.25 has full window functions, which is sufficient for most of Timescale's hyperfunction surface. No C extension required.

| Function | Implementation |
|---|---|
| `time_bucket/2` | `(ts / width) * width` on integer epochs |
| `first/2`, `last/2` | `FIRST_VALUE` / `LAST_VALUE` with explicit frame |
| `locf/1` | Gaps-and-islands: `COUNT(value) OVER (... ROWS UNBOUNDED PRECEDING)` as group key, then `MAX(value) OVER (PARTITION BY key)` — SQLite lacks `IGNORE NULLS` |
| `interpolate/1` | `LAG` / `LEAD` plus linear arithmetic |
| `time_weighted_average/1` | `SUM(value * dt) / SUM(dt)` where `dt = ts - LAG(ts)` |
| `delta/1`, `rate/1` | `LAG` on counters, with reset detection |
| `time_bucket_gapfill/2` | Recursive CTE generating buckets, `LEFT JOIN`ed to data |
| `histogram/2` | `CASE`-bucketed `COUNT` with a generated bounds CTE |

These are Elixir functions returning SQL fragments, composable with Ecto and usable directly.

### 9.2 Three access levels

```elixir
# 1. High-level — the common case
Barograph.query(db, "engine_temp",
  labels: %{forklift: "FL-07"},
  from: ~U[2026-07-01 00:00:00Z],
  to: ~U[2026-07-19 00:00:00Z],
  bucket: {1, :hour},
  agg: :avg
)

# 2. Ecto composable
import Barograph.Query
from(s in Barograph.samples(db),
  where: s.series_id in subquery(matching_labels(%{site: "tallinn"})),
  group_by: time_bucket(s.ts, {15, :minute}),
  select: {time_bucket(s.ts, {15, :minute}), time_weighted_average(s.value)}
)

# 3. Raw SQL — always available, never second-class
Barograph.sql(db, "SELECT ... FROM bg_samples JOIN bg_series ...")
```

Level 3 is a hard requirement, not a convenience. Every design decision above is checked against "does this remain queryable with `sqlite3` and no library?"

### 9.3 Time-weighted average

Called out specifically because it is the most commonly needed and most commonly botched operation on irregular sensor data. A naive `AVG(value)` over unevenly spaced samples is simply wrong; integrating instantaneous power into energy requires weighting by interval. Barograph provides this in the aggregate state, so it is correct at every rollup level.

---

## 10. Ingestion

### 10.1 Graphite plaintext line protocol (primary)

```
metric.path.name value timestamp\n
```

Chosen because collectd (`write_graphite`), Telegraf, Vector, statsd, and Grafana Alloy all already speak it. Roughly forty lines of `ThousandIsland` handler buys the entire existing agent ecosystem.

Dotted paths map to metric plus labels via a configurable template, following Graphite's own tag conventions:

```
forklift.FL-07.engine.temp  94.2  1752931200
→ metric: "engine.temp", labels: %{forklift: "FL-07"}
```

Graphite 1.1+ tag syntax (`metric;tag=value`) is parsed natively where present.

### 10.2 Native API

```elixir
Barograph.write(db, "engine_temp", %{forklift: "FL-07"}, 94.2)
Barograph.write(db, "engine_temp", %{forklift: "FL-07"}, 94.2, ts)
Barograph.write_many(db, samples)
Barograph.write_event(db, "fault", %{forklift: "FL-07"}, %{code: "0x2A"})
```

### 10.3 Deliberately excluded

- **Prometheus remote_write** — protobuf plus snappy; snappy means a NIF, for a protocol whose users already run Prometheus.
- **collectd binary network protocol** — fiddly, and the install base is shrinking. `write_graphite` covers those users.
- **OTLP** — reconsider post-1.0. Correct long-term target, disproportionate effort for v1.

### 10.4 Store-and-forward

For edge deployments, `Barograph.Forwarder` reads local data above a cursor and pushes to a remote Barograph (or any Graphite endpoint), advancing the cursor on acknowledgement. Survives connectivity loss without buffering in memory — the local file *is* the buffer.

This is the primary Nerves use case: the forklift Pi writes locally, forwards opportunistically over 4G, and loses nothing when the modem drops.

---

## 11. Rendering — Barogram

A *barogram* is the trace a barograph produces. `Barograph.Barogram` produces SVG as a string.

```elixir
Barograph.Barogram.svg(result, width: 800, height: 200, style: :line)
```

### 11.1 Why SVG, not PNG

- No image encoder, no NIF, no headless browser.
- Text output — diffs efficiently over a LiveView websocket.
- Crisp at any DPI.
- CSS-themeable by the host application.
- Hoverable points and tooltips without a client-side charting library.

RRDtool renders PNG because 1999 offered nothing better. That constraint no longer applies.

### 11.2 Outputs

- Inline heex for LiveView
- Standalone `.svg` string
- Optional signed-URL endpoint (`/barogram.svg?...`) for embedding in contexts with no BEAM, mirroring the ergonomics of rrdsrv's signed graph queries

### 11.3 Scope limit

Line, area, step, and scatter. Axis rendering, gridlines, legends. No dashboarding, no interactivity beyond hover, no panel layout. Anyone needing more should query Barograph and hand the data to a real charting library.

---

## 12. Storage adapter behaviour

Although SQLite is the reference implementation, storage sits behind a behaviour — the same adapter pattern used in the payments and email modules.

```elixir
@callback init(opts) :: {:ok, state} | {:error, term}
@callback write_samples(state, [sample]) :: :ok | {:error, term}
@callback query(state, query) :: {:ok, result} | {:error, term}
@callback create_chunk(state, range) :: :ok
@callback drop_chunks(state, before) :: {:ok, non_neg_integer}
@callback refresh_aggregate(state, name, range) :: :ok
```

Planned adapters:

| Adapter | Status | Purpose |
|---|---|---|
| `Barograph.Store.SQLite` | v1 | Reference implementation |
| `Barograph.Store.Postgres` | post-1.0 | Declarative partitioning + Elixir-computed rollups; no Timescale, no TSL |
| `Barograph.Store.RingFile` | speculative | Pure-Elixir fixed-size ring buffer via `:file.pread/pwrite`, for zero-NIF Nerves targets |

The `RingFile` design is documented in Appendix A but is explicitly not v1 scope.

---

## 13. Dependencies

| Dependency | Required | Purpose |
|---|---|---|
| `exqlite` | yes | SQLite driver. **Is a NIF** — bundles the C amalgamation, compiled from source via `elixir_make`. No precompiled binaries, no vector instructions, no AVX/SIGILL class of failure. |
| `ecto_sqlite3` | optional | Ecto integration |
| `oban` | optional | Aggregate refresh scheduling; falls back to internal timers |
| `thousand_island` | optional | Graphite listener; only loaded when ingest is configured |
| `jason` | no | Label and payload JSON — handled by Elixir's built-in `JSON` module (stdlib since 1.18), no dependency needed |

No Rust NIFs. No precompiled artifacts. Everything compiles from source on the target.

---

## 14. Roadmap

### v0.1 — vertical slice
- Open/create database, metadata, migrations
- `bg_series` + `bg_samples` schema, series cache
- `Barograph.Writer` with batching and back-pressure
- `Barograph.write/4`, `write_many/2`
- `time_bucket` queries with `avg`/`min`/`max`/`sum`/`count`
- One continuous aggregate with watermark refresh
- Basic `Barogram.svg/2` line chart

**Exit criterion**: ingest 10k samples/sec sustained on an RPi 5, query a month of 1-minute data in under 100 ms.

### v0.2 — ingestion and retention
- Graphite line protocol listener
- Retention policies, chunk creation and drop (`:tables` backend)
- Incremental vacuum job
- Hierarchical rollups

### v0.3 — query surface
- Full hyperfunction set (§9.1)
- Ecto composable API
- Gap filling, `locf`, interpolation
- Events table and mixed sample/event queries

### v0.4 — edge
- `:files` chunk backend
- `Barograph.Forwarder` store-and-forward
- Nerves example project

### v0.5 — presentation
- Barogram: area, step, scatter, axes, legends
- Signed-URL rendering endpoint
- `phoenix_kit_stats` integration (separate package)

### v1.0
- API stability commitment
- Documented file format version
- Benchmark suite versus TimescaleDB and raw SQLite
- Migration guide from RRDtool

### Post-1.0
- Postgres adapter
- OTLP ingestion
- Columnar batching (§7.6), if the raw-SQL cost can be justified

---

## 15. Open questions

1. **Chunk backend default.** `:tables` preserves raw SQL; `:files` reclaims disk. Is disk reclamation important enough on Nerves to make `:files` the default there? Leaning no — document the trade and let users choose.

2. **Downsampling on read vs. write.** Should `query/3` automatically route to the coarsest aggregate satisfying the requested bucket width, as Timescale does not but Grafana users expect? Convenient, but it makes query cost non-obvious. Leaning toward explicit opt-in via `resolve: :auto`.

3. **Cardinality limits.** At what active series count does SQLite index maintenance become the bottleneck? Needs measurement before publishing a number. Suspect 10k–50k on ARM.

4. **Counter reset semantics.** Prometheus-style reset detection assumes monotonicity. Should `rate/1` guess, or require the series to be declared a counter at creation? Leaning toward explicit declaration — guessing is where Prometheus surprises people.

5. **Multi-tenancy.** One database file per tenant, or a tenant label? Per-file gives clean isolation and trivial deletion; per-label gives cross-tenant queries. Possibly both, decided by the host application.

6. **Time unit migration.** Currently fixed at creation. Is a migration path needed, or is "create a new database and forward" acceptable? Leaning acceptable for v1.

---

## Appendix A — RingFile format (speculative, not v1)

For zero-NIF targets, a pure-Elixir fixed-size ring buffer using `:file.pread/pwrite` in `:raw` mode with binary pattern matching. Stdlib only.

Key simplification over RRDtool: derive the slot from the timestamp rather than maintaining a write pointer.

```
slot   = rem(div(ts, step * pdp_per_row), rows)
offset = rra_base + slot * (8 + ds_count * 8)
```

Each slot stores its own bucket timestamp alongside values. Consequences: writes are idempotent; out-of-order arrivals within the window work naturally; stale-versus-wrapped is decided by comparing stored timestamp against expected. No pointer to corrupt, no recovery logic.

**Layout**

- Header: magic, format version, step, DS definitions (name, type, heartbeat, min, max), RRA definitions (consolidation function, `pdp_per_row`, `rows`), `last_update`
- Body: per RRA, `rows × (8 + ds_count × 8)` bytes of float64

**Consolidation**: in-memory PDP accumulator per datasource (count, sum, min, max, last), flushed to RRA slots on step boundaries. Held in ETS with periodic flush so writes never block on a single process.

**Known limitation**: crash-consistency is the caller's problem. Preallocation means no metadata mutation and 8-byte aligned writes rarely tear, but power loss mid-flush can leave one bucket garbage. Acceptable for metrics — but it must be an accepted risk, not an unexamined one.

Even here, labels would not be dropped: a small label map hashed to a series ID, so the ring-buffer economics are kept without inheriting RRDtool's dimensional blindness.

---

## Appendix B — Positioning

**One-liner**: Time-series and event analytics for Elixir, stored in SQLite. One file, no server, full SQL.

**Where Barograph wins**: inside a Nerves firmware; in a single-binary release; on a developer's laptop; in a client project that must not grow a ninth service; anywhere the storage artifact needs to be a file you can copy.

**Where it loses**: sustained ingest above ~50k samples/sec; multi-terabyte retention; horizontal scale; anything needing PromQL. Recommend TimescaleDB, ClickHouse, or VictoriaMetrics without hesitation.

**Launch narrative**: collectd has not cut a stable release since 5.12.0 in September 2020 and its 6.0 rewrite is still at rc3; RRDtool shipped 1.10.3 in May 2026. The collection agent got displaced by Prometheus and Telegraf, but the embedded storage engine never did — because nothing replaced what it actually offered. That gap is worth revisiting on the BEAM, where serialised writes and scheduled refresh are native strengths rather than obstacles.
