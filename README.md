# Barograph

Barograph — time-series and event analytics for Elixir, stored in SQLite. One file. No server. Full SQL.

## Quick start

```elixir
# mix.exs
def deps do
  [
    {:barograph, "~> 0.2.0"}
  ]
end
```

```elixir
{:ok, db} = Barograph.open("metrics.bg")

Barograph.write(db, "engine_temp", %{forklift: "FL-07"}, 94.2)

{:ok, points} =
  Barograph.query(db, "engine_temp",
    labels: %{forklift: "FL-07"},
    bucket: {1, :hour},
    agg: :avg
  )

svg = Barograph.Barogram.svg(points)
```

No server to run, no schema to migrate — `open/2` creates and initialises the
file on first use, and the writer is supervised automatically. Raw SQL is
always available via `Barograph.sql/3`; see [Design take](#design-take) below
for batching, continuous aggregates, and the rest of the design.

### Ingesting from existing agents

Add `{:thousand_island, "~> 1.5"}` to `mix.exs` and pass `:ingest` to
`open/2` to accept the Graphite plaintext line protocol — already spoken by
collectd, Telegraf, Vector, statsd, and Grafana Alloy, so this is often
"point your existing agent at Barograph" rather than writing a collector:

```elixir
{:ok, db} = Barograph.open("metrics.bg", ingest: [graphite: [port: 2003]])
```

```
$ echo "engine_temp 94.2 1752931200" | nc localhost 2003
```

By default the whole dotted path becomes the metric name with no labels.
Pass a `:template` to split label values out of the path instead:

```elixir
Barograph.open("metrics.bg",
  ingest: [graphite: [port: 2003, template: "*.forklift.metric"]]
)
```

```
$ echo "forklift.FL-07.engine.temp 94.2 1752931200" | nc localhost 2003
# → metric: "engine.temp", labels: %{"forklift" => "FL-07"}
```

Graphite 1.1+ tag syntax (`metric;tag=value`) is also parsed natively,
independent of any template. The protocol has no authentication and binds
all interfaces by default — see `Barograph.Ingest.Supervisor`'s moduledoc
for the full option list (including `transport_options: [ip: :loopback]`)
before exposing a listener beyond local development.

### One file, or many?

Barograph has no concept of "source," "device," or "tenant" — only metric
name + labels within whatever file you open. How many files to use is a
host-application decision, not something the library prescribes. Multiple
databases may be open at once, so both of these are equally valid:

```elixir
# One shared file, sources distinguished by a label
{:ok, db} = Barograph.open("fleet.bg")
Barograph.write(db, "engine_temp", %{forklift: "FL-07"}, 94.2)
Barograph.write(db, "engine_temp", %{forklift: "FL-08"}, 88.9)

# One file per source, sensors distinguished by metric name
{:ok, db} = Barograph.open("forklift_FL-07.bg")
Barograph.write(db, "engine_temp", %{}, 94.2)
Barograph.write(db, "battery_voltage", %{}, 48.1)
```

Shared file: cross-source queries are trivial SQL (`GROUP BY labels`), one
writer GenServer for everything. Per-source file: clean isolation and
trivial deletion (`File.rm/1`), independent retention per source, at the
cost of cross-source queries needing multiple opens. Pick based on whether
isolation (deletion, retention, export) or cross-source querying matters
more for your use case.

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

v0.1 is a tight vertical slice: schema, series cache, batched writer, one continuous aggregate with watermark refresh, and a basic SVG line chart — with a concrete exit criterion (10k samples/sec sustained on an RPi 5; a month of 1-minute data queried in under 100 ms). v0.2 adds ingestion — the Graphite plaintext line protocol listener above is shipped. Retention, the full hyperfunction set, edge store-and-forward, and richer Barogram output remain on the v0.2–v0.5 roadmap.

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
