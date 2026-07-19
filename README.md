# Barograph

Barograph — time-series and event analytics for Elixir, stored in SQLite. One file. No server. Full SQL.

## Design take

Notes on the technical specification in [dev_docs/barograph-spec.md](dev_docs/barograph-spec.md).

### What it is

An embedded time-series/event database for Elixir backed by a single SQLite file, with TimescaleDB-shaped ergonomics: hypertables, continuous aggregates, retention policies, time-bucketed queries, and SVG chart rendering (Barogram). Apache-2.0, no feature gating. The name nods to RRDtool's ancestor — the 1844 barograph, a round-robin recorder that predates computers by a century.

### Core design bets

- **Single writer GenServer + WAL readers.** SQLite's one-writer limitation becomes the natural BEAM shape rather than a problem to engineer around. Batched transactions (1000 samples or 100 ms, whichever first) buy roughly two orders of magnitude over per-row autocommit, because each autocommit is an fsync.
- **Prometheus-style series identity.** Labels are canonicalised, hashed (BLAKE2b truncated to 16 bytes) to a series ID; samples live in a `WITHOUT ROWID` table keyed `(series_id, ts)` so range scans are sequential. The JSON labels column is kept redundantly on purpose — the hash is for the write path, the JSON is for humans writing SQL by hand.
- **Partial aggregate state, never final values.** Continuous aggregates store `count`/`sum`, never `avg`. That single rule makes hierarchical rollups compose (`1m → 1h → 1d` without rescanning raw data) and keeps time-weighted averages correct at every level. Getting this wrong is the most common failure in hand-rolled rollup systems.
- **Raw SQL as a hard requirement.** Every design decision is checked against "can `sqlite3` answer this without the library?" This is exactly why columnar compression is deferred (compressed chunks would be opaque to raw SQL) and why `:tables` is the default chunk backend over `:files`.

### Sharpest trade-offs

- **Chunking** (§6 of the spec): `:tables` keeps everything in one file and raw-SQL queryable but needs incremental vacuum to reclaim space; `:files` makes retention a true `File.rm/1` but breaks ad-hoc SQL across chunks. Leaning `:tables` as default everywhere, including Nerves — document the trade and let users choose.
- **`synchronous = NORMAL` under WAL** risks losing the last transaction on power loss (never corruption). The right trade for metrics; configurable to `FULL` for callers who disagree.
- **Hyperfunctions as generated SQL** over SQLite window functions — no C extension needed. The gaps-and-islands workaround for `locf` (SQLite lacks `IGNORE NULLS`) is the kind of detail that makes this feasible rather than hand-wavy.
- **Late data** is handled by `INSERT OR REPLACE` idempotency plus dirty-bucket invalidation below the aggregate watermark — bounded, crash-safe, and honest about its horizon limit.

### Roadmap shape

v0.1 is a tight vertical slice: schema, series cache, batched writer, one continuous aggregate with watermark refresh, and a basic SVG line chart — with a concrete exit criterion (10k samples/sec sustained on an RPi 5; a month of 1-minute data queried in under 100 ms). Ingestion (Graphite line protocol), retention, the full hyperfunction set, edge store-and-forward, and richer Barogram output follow in v0.2–v0.5.

### Open questions (§15)

Well-posed, and the spec's leanings look right on all of them: keep `:tables` the default chunk backend, make aggregate auto-routing explicit opt-in (`resolve: :auto`), require counters to be declared rather than guessed for `rate/1`, and leave per-file vs per-label tenancy to the host application.

## Development

```
mix quality
```

Runs the full gate: format check, compile with warnings as errors,
`hex.audit`, `credo --strict`, the test suite, and `dialyzer`. All of it
must pass before a change lands.

## License

Apache-2.0. Every feature — no community edition, no source-available tier.
