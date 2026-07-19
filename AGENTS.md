# AGENTS.md

Instructions for coding agents working in this repository.

## What this is

Barograph — time-series and event analytics for Elixir, stored in SQLite.
One file, no server, full SQL. Read [dev_docs/barograph-spec.md](dev_docs/barograph-spec.md)
before making design decisions; it is the source of truth and is kept
synced with what actually shipped. Read
[dev_docs/2026-07-19-progress-report.md](dev_docs/2026-07-19-progress-report.md)
for current status, known limitations, and the history of independent
reviews (findings B1–B10, fixes applied, and B6–B9 deferred-by-design
and already ticketed for v0.2 — don't re-report those as new findings).

Deferred-by-design for v0.1 (see the spec's roadmap, §14, and the
progress report's "Known limitations"): chunking, the events API, a
real read connection pool, Ecto integration, the real-time aggregate
view. These are intentional scope cuts, not gaps.

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
test/barograph/              one test file per lib module, plus benchmark_test.exs (excluded by default)
dev_docs/                    spec and progress report
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
