# Progress report — 2026-07-20

v0.2, piece 1: the Graphite plaintext ingest listener (spec §10.1), per
the plan in `dev_docs/barograph-spec.md`'s roadmap §14. v0.1's other
v0.2 items — retention/chunk drop, incremental vacuum, hierarchical
rollups — and the B6–B9 fixes ticketed in the v0.1 report are separate,
not covered here.

## Done

- `mix.exs`: `{:thousand_island, "~> 1.5", optional: true}`.
- `Barograph.Ingest.Graphite.Parser` (`lib/barograph/ingest/graphite/parser.ex`):
  pure line parsing. `compile_template/1` / `apply_template/2` implement
  the template grammar documented in spec §10.1 (`"*"` skip, literal
  label-key tokens, single trailing `"metric"` token that greedily
  consumes the remainder of the path). `parse_line/2` dispatches to
  Graphite 1.1+ tag syntax (`metric;tag=val;...`) when a `;` is present,
  independent of any template, otherwise applies the template. Rejects
  wrong field counts, non-numeric values, the literal `"nan"` value
  (collectd's `write_graphite` uses this for undefined datapoints —
  `bg_samples.value` is `REAL NOT NULL`), and non-integer timestamps.
- `Barograph.Ingest.Supervisor` (`lib/barograph/ingest/supervisor.ex`):
  one `ThousandIsland` child per configured protocol (`:graphite` only),
  `:one_for_one`. Compiles the template once at supervisor `init/1`
  rather than per connection/line. Runtime `Code.ensure_loaded?/1` guard
  in `start_link/1` returns `{:error, {:missing_dependency, :thousand_island}}`
  if the optional dep truly isn't present.
- `Barograph.Ingest.Graphite` (`lib/barograph/ingest/graphite.ex`): the
  `ThousandIsland.Handler` — buffers partial lines across TCP reads,
  parses all complete lines per `handle_data/3` call, calls
  `Barograph.write_many/2` once per read (not once per line), converts
  Graphite's unix-second timestamps to the database's configured time
  unit, skip-and-logs malformed lines without closing the connection,
  and bounds per-connection buffer growth with `:max_line_length`
  (default 8192 bytes). Entire module wrapped in
  `if Code.ensure_loaded?(ThousandIsland) do ... end` — see AGENTS.md's
  "Optional-dependency guard" convention note.
- `Barograph.Database` (`lib/barograph/database.ex`): opt-in
  `Barograph.Ingest.Supervisor` child, added last in the `:rest_for_one`
  chain, only when `:ingest` is given to `Barograph.open/2`.
- `Barograph.open/2` doc updated for the new `:ingest` option; no code
  change needed there — the existing `opts` pipeline already threads it
  through.
- Manually smoke-tested end-to-end against a real `iex -S mix` /
  `mix run` session with a genuine `:gen_tcp` client (a `Barogram.svg/2`
  render of ingested points came out to 1503 bytes of well-formed SVG),
  confirming the integration point external agents will actually hit.

## Deviations from the spec (decisions taken during implementation)

1. **`:ingest` is an option to `Barograph.open/2`, not app-wide config.**
   The spec's original §4.1 diagram drew `Barograph.Ingest.Supervisor`
   as a top-level sibling of `DatabaseSupervisor`, implying
   Application-env-driven setup. Every other option in this library
   flows through `open/2`, and no other Application-env config surface
   exists anywhere in the codebase. Spec §4.1 updated to match — see
   the deviation note directly in the diagram there.
2. **Ingest-derived labels are string-keyed, not atom-keyed.** The
   spec's own §10.1 example used an atom key (`labels: %{forklift: "FL-07"}`).
   Tag-syntax label *keys* come directly off the wire from an external,
   possibly adversarial agent; converting network-controlled text to
   atoms via `String.to_atom/1` is an unbounded atom-creation DoS
   (atoms are never garbage collected). Verified this doesn't split
   series identity in two: `Barograph.Labels.canonical/1` interpolates
   keys via `"#{key}=#{value}"`, which stringifies atom and binary keys
   identically, so a native write with `%{forklift: "FL-07"}` and an
   ingested sample with `%{"forklift" => "FL-07"}` hash to the same
   series. `Barograph.Query`'s label filter and `JSON.encode!/1` are
   likewise key-type-agnostic. Spec §10.1 updated with the real grammar
   and a string-keyed example.

## Known limitations

- The fully-tagged Graphite syntax with no bare metric-name prefix
  (`;tag=val`, no `metric;` before it) is not supported — only
  `metric;tag=val`.
- The "`thousand_island` genuinely absent" path
  (`Barograph.Ingest.Supervisor.start_link/1`'s
  `{:error, {:missing_dependency, :thousand_island}}` branch) can't be
  exercised in-process: this repo's own dev/test env always has the
  optional dep resolved, since that's what makes the rest of this
  feature testable at all.
- `:max_line_length` is an approximate, not exact, bound on
  per-connection buffer growth — checked post-concatenation, so the
  worst case is `max_line_length` plus one TCP read's worth of bytes.
- No application-level acknowledgement in the Graphite plaintext
  protocol — a writer `{:error, :overloaded}` (spec §7.2 back-pressure)
  is logged and the batch dropped, with no way to signal back-pressure
  to the sending agent. Same fire-and-forget posture as UDP-based
  statsd.

## Unrelated finding (not fixed here, out of scope for this pass)

While smoke-testing, `Barograph.Query.run/3` (`lib/barograph/query.ex:42`)
was found to raise `ArgumentError` (`String.to_existing_atom/1`, "not an
already existing atom") on a `query/3` call in a process where
`Barograph.Barogram` has never been loaded — the `:ts`/`:value`/`:bucket`
atoms this code relies on already existing are, today, only created as a
side effect of `Barogram`'s own pattern matches (`lib/barograph/barogram.ex:62-63`)
happening to be compiled somewhere already-loaded. Every existing test
passes only because ExUnit compiles and loads the whole `test/` tree
(including files with literal `%{ts: ..., value: ...}` maps) up front,
masking the issue. Repro: a bare `mix run` script that opens a database,
writes a sample, and calls `Barograph.query/3` without ever touching
`Barograph.Barogram` first. This affects any consumer using Barograph
purely for storage+query without rendering — a use case this project
explicitly supports — and is unrelated to the Graphite ingest work in
this report; it predates it and touches neither file this pass changed.
Worth a dedicated fix (e.g. `String.to_atom/1` is safe here specifically,
since the three column names come from the SQL fragment generator, never
from user input).

## Test status

`mix test`: 89 tests, 0 failures (2 excluded: benchmarks). New files:
`test/barograph/ingest/graphite/parser_test.exs` (pure, 18 tests),
`test/barograph/ingest/supervisor_test.exs` (4 tests),
`test/barograph/ingest/graphite_test.exs` (real `:gen_tcp` end-to-end, 6
tests). `mix quality` (hex.audit, format, compile --warnings-as-errors,
credo --strict, test, dialyzer) passes clean.
