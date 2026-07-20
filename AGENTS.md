# AGENTS.md

Instructions for coding agents working in this repository.

## What this is

Barograph — time-series and event analytics for Elixir, stored in SQLite.
One file, no server, full SQL. Read [dev_docs/barograph-spec.md](dev_docs/barograph-spec.md)
before making design decisions; it is the source of truth and is kept
synced with what actually shipped. Read
[dev_docs/2026-07-19-progress-report.md](dev_docs/2026-07-19-progress-report.md)
(v0.1) and [dev_docs/2026-07-20-progress-report.md](dev_docs/2026-07-20-progress-report.md)
(v0.2, Graphite ingest) for current status, known limitations, and the
history of independent reviews (findings B1–B10, fixes applied, and
B6–B9 deferred-by-design and already ticketed for v0.2 — don't re-report
those as new findings).

Deferred-by-design for v0.1 (see the spec's roadmap, §14, and the
progress report's "Known limitations"): chunking, the events API, a
real read connection pool, Ecto integration, the real-time aggregate
view. These are intentional scope cuts, not gaps.

File granularity (one shared file vs. one file per source/tenant/device)
is a host-application decision — Barograph has no concept of "source" or
"tenant," only metric name + labels within a file, and multiple databases
may be open simultaneously (spec §15 Q5). Don't add source/tenant-scoping
machinery to the library itself; that belongs in the caller. The same
philosophy applies to ingest listeners (spec §10, §4.1): configured via
the `:ingest` option on `Barograph.open/2`, not Application-env config —
see `Barograph.Ingest.Supervisor`'s moduledoc for the reasoning.

## Layout

```
lib/barograph.ex            public API (open/close/write/query/sql/…)
lib/barograph/
  application.ex             OTP application, top-level supervisor
  database.ex                per-database supervisor (:rest_for_one)
  schema.ex                  DDL + file metadata, create/validate on open
  writer.ex                  single-writer GenServer: batching, back-pressure
  series_cache.ex            ETS label-hash -> series_id cache
  labels.ex                  label canonicalisation + BLAKE2b hashing
  query.ex                   time_bucket query builder (spec §9)
  sql.ex                     raw SQL, level-3 query API (hard requirement)
  rows.ex                    shared prepared-statement draining (see below)
  aggregate.ex               continuous aggregates: partial state, watermark, invalidation
  refresher.ex               internal timer-driven aggregate refresh
  barogram.ex                SVG line-chart rendering
  ingest/
    supervisor.ex             opt-in per-database ingest listener supervisor (spec §10)
    graphite.ex                Graphite plaintext listener (ThousandIsland.Handler; guarded, see below)
    graphite/parser.ex         pure line/template/tag parsing, no dependency on thousand_island
test/barograph/              one test file per lib module, plus benchmark_test.exs (excluded by default)
  ingest/                     mirrors lib/barograph/ingest/
dev_docs/                    spec and progress reports
```

## Working here

Run the full quality gate before considering any change done:

```
mix quality
```

This chains `hex.audit`, `format --check-formatted`,
`compile --force --warnings-as-errors`, `credo --strict` (config in
`.credo.exs`), `test`, and `dialyzer` (PLT cached under `priv/plts/`,
gitignored — first run is slow, later runs are fast). All of it must
pass. Individual steps: `mix format`, `mix test`, `mix credo --strict`,
`mix dialyzer`.

Elixir `~> 1.19`, OTP 28. Only required runtime dependency is
`exqlite` (a NIF — no precompiled binaries, compiles from source). No
`jason` — label/payload JSON uses the stdlib `JSON` module.

## Conventions established in this codebase

- **Single writer, ephemeral readers.** All writes funnel through one
  `Barograph.Writer` GenServer per database (owns the sole write
  connection, batches, back-pressures). Reads open a short-lived WAL
  connection per call — no pooling yet (v0.3, with Ecto). Don't route
  reads through the writer.
- **Partial aggregate state, never final values.** Continuous
  aggregates store `count`/`sum`, never `avg` (spec §8.2). This is
  deliberate and load-bearing — don't "simplify" it away.
- **Two error-handling idioms, used deliberately, not interchangeably**:
  Result tuples (`{:ok, _} | {:error, _}`) at public API boundaries and
  anywhere a caller can act on failure; bare pattern-match-or-crash
  (`:ok = ...`, `:done = ...`) for internal DB bookkeeping that should
  never fail under normal operation and is fine to let crash into a
  supervisor restart. See `Barograph.Rows.fetch_all/2` (Result) vs
  `fetch_all!/2` (raises) for the precedent — pick whichever matches
  what the call site already does, don't introduce a third style.
- **Never silently swallow a partial failure.** The whole reason
  `Barograph.Rows` exists: `Exqlite.Sqlite3.step/2` can return `:busy`
  or `{:error, reason}` *after* already yielding rows, and treating
  that the same as `:done` (e.g. via
  `Stream.take_while(&match?({:row, _}, &1))`) silently returns
  truncated data as if the query succeeded. Always drain a prepared
  statement through `Barograph.Rows`, never hand-roll the loop.
- No comments explaining *what* code does; only for a non-obvious
  *why* (a spec section, a subtle invariant, a workaround). Match the
  existing style — most functions have zero comments.
- Spec deviations are real decisions, not oversights — see the
  progress report's "Deviations from the spec" section before
  "fixing" something that looks inconsistent with the spec text.
- **Optional-dependency guard.** `Barograph.Ingest.Graphite` is the only
  module in the codebase wrapped in
  `if Code.ensure_loaded?(ThousandIsland) do defmodule ... end`. This is
  intentional, not accidental indentation: `thousand_island` is an
  `optional: true` dep (spec §13), and a downstream app that never adds
  it must still be able to `mix compile` — Mix compiles this library's
  `lib/` regardless of whether a consumer's own deps include the
  optional ones. Only the actual `ThousandIsland.Handler` needs the
  guard; `Barograph.Ingest.Graphite.Parser` is pure and always compiles,
  and `Barograph.Ingest.Supervisor` only builds child-spec tuples /
  refers to the handler by bare module name (both fine without the dep
  loaded) and does its own **runtime** `Code.ensure_loaded?/1` check in
  `start_link/1` instead, since it's the one that actually needs to call
  into `ThousandIsland.*`.
- **Ingest-derived labels are string-keyed, not atom-keyed** — see spec
  §10.1's rationale (unbounded atom creation from network input) and the
  v0.2 progress report. Verified harmless: `Barograph.Labels.canonical/1`
  stringifies both key types identically, so series identity is
  unaffected by which entry path (native API vs. ingest) wrote a sample.
