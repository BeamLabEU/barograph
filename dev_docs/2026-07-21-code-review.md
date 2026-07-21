# 2026-07-21 Code review — v0.2 Graphite ingest and follow-ups

Review of recent commits on `main` since `c48c5e0` through `HEAD`
(`e8a211a`): Graphite plaintext ingest listener, `Query.run/3` atom-existence
fix, and the 0.2.0 version bump.

- **Scope:** 15 files, +895 / −24
- **Issue counts:** 3 bugs, 5 suggestions, 2 nits
- **Working tree at review time:** clean; branch was ahead of `origin/main`
  by the query fix and version-bump commits (Graphite already on origin)

## Summary

v0.2 ships a clean Graphite plaintext ingest path (pure parser, opt-in
ThousandIsland handler under `Barograph.Database`, string-keyed labels,
documented `open/2` `:ingest` deviation) plus a solid fix for `Query.run/3`’s
atom-existence crash. Architecture matches AGENTS.md/spec conventions
(optional-dep guard, single-writer batching, rest_for_one placement). Dominant
risks are in the network-facing handler: `:max_line_length` is not actually
enforced on complete lines / post-split remainder, and several `String.*` calls
on untrusted TCP bytes can raise instead of skip-and-continue. Tests cover the
happy path and basic failure modes well; template e2e, line-length limits, and
non-second time units on ingest are untested.

## What looks good

- Optional-dep compile guard + runtime `Code.ensure_loaded?` in the supervisor
- Ingest-derived labels string-keyed (avoids atom exhaustion)
- Ingest on `open/2`, not app env
- Query fix with explicit `atomize_row/1` over known columns
- E2E tests for fragmentation, multi-line packets, malformed resilience, tags,
  multi-connection

## Issues

### Issue 1 -- Severity: bug

- File: lib/barograph/ingest/graphite.ex:31-38
- Description: `:max_line_length` is only checked when the buffer contains
  **no** newline. A single TCP segment of the form `short_ok_line\n` <>
  `huge_payload` (or `huge_payload\n`) bypasses the guard, leaves `rest` larger
  than the limit after `split_lines/1`, and will fully parse/log an oversized
  complete line on the next `\n`. That contradicts the stated purpose of
  bounding per-connection buffer growth (and is worse than the documented
  “max + one TCP read” approximation, because complete lines are never
  size-checked at all). There is also no test covering the limit.
- Suggestion: After `split_lines/1`, reject (close connection or drop) if any
  complete line’s `byte_size/1` exceeds `max_line_length`, and if
  `byte_size(rest) > max_line_length`. Prefer binary size checks over
  `String.contains?/2`. Add an e2e test that sends an oversized line and
  asserts disconnect / no hang / bounded buffer.
- Status: fixed — handle_data/3 now checks byte_size of every post-split complete line and the trailing remainder, not the pre-split buffer. Regression tests added for both the simple oversized-line case and the specific bypass (short line + newline-less huge remainder in one read).

### Issue 2 -- Severity: bug

- File: lib/barograph/ingest/graphite/parser.ex:82-126
- Description: Parsing is implemented with `String.split/1`,
  `String.trim_trailing/2`, `String.downcase/1`, etc. on data that comes
  straight off TCP. In particular `String.downcase/1` (used for the `"nan"`
  reject path) requires valid UTF-8 and raises `ArgumentError` on invalid
  bytes. A single non-UTF-8 value field therefore crashes the handler process
  and drops the connection, contradicting the handler’s “skip malformed lines
  without closing the connection” contract (covered in tests only for
  well-formed UTF-8 garbage). `graphite.ex`’s `String.contains?(buffer, "\n")`
  / `String.split(buffer, "\n")` have the same class of risk depending on
  Elixir’s UTF-8 validation for those calls.
- Suggestion: Treat the wire format as raw binaries: use `:binary.split/3`,
  `:binary.match/2`, and ASCII-only comparisons (e.g.
  `str in ["nan", "NaN", "NAN"]` or a byte-wise downcase for the three-letter
  case). Ensure any raise in `parse_line/2` is impossible so `handle_data/3`
  can keep skipping bad lines. Add a test that sends a line with an
  invalid-UTF-8 value field and asserts a later valid line still lands.
- Status: fixed, root cause revised — verified empirically that String.downcase/1, String.split/1, String.trim_trailing/2, and String.contains?/2 do NOT raise on invalid UTF-8 on this project's Elixir 1.19.5 runtime (tested directly; none of the four raised on lone continuation bytes, overlong encodings, surrogate halves, or out-of-range sequences). The real crash is downstream: an invalid-UTF-8 label value (from tag syntax or a template-derived path segment) reaches JSON.encode! in Barograph.Writer.insert_series/4 and crashes the Writer GenServer itself — worse than the reviewed concern, since :rest_for_one cascades that into restarting the refresher and every other open ingest connection, not just the one bad connection. Fixed by validating String.valid?/1 on the metric and every label key/value in Parser.parse_line/2, rejecting the line before it ever reaches the write path. Reproduced pre-fix (confirmed Writer crash via a real TCP line) and post-fix (confirmed no crash, writer stays up) manually; regression tests added at both the pure-parser and TCP end-to-end level.

### Issue 3 -- Severity: bug

- File: README.md:11
- Description: Quick-start still pins `{:barograph, "~> 0.1.0"}` while
  `mix.exs` ships `@version "0.2.0"`. Anyone copying the README after the 0.2
  release will not get the Graphite ingest surface the same README documents
  immediately below.
- Suggestion: Bump the README dep example to `~> 0.2.0` (or `~> 0.2`) as part
  of the version bump commit.
- Status: fixed — README dep example bumped to ~> 0.2.0.

### Issue 4 -- Severity: suggestion

- File: lib/barograph/ingest/supervisor.ex:45-56
- Description: The Graphite listener is started with only `port` / handler
  options. There is no way to pass ThousandIsland `transport_options` (e.g.
  `ip: :loopback` or a specific interface). Erlang’s default listen address is
  all interfaces, and Graphite plaintext has no auth. For a library that also
  stores data on disk, “open metrics port on 0.0.0.0” is a sharp edge that
  README/examples never mention.
- Suggestion: Plumb `transport_options:` (or a first-class `:ip` option) from
  `graphite:` config into the ThousandIsland child spec, defaulting to current
  behaviour; document that production deployments should bind loopback or a
  private interface / put the port behind a firewall. Optionally default
  test/dev docs to `ip: :loopback`.
- Status: fixed — `transport_options` now passed through from `graphite:` config into the ThousandIsland child spec (e.g. `transport_options: [ip: :loopback]`), documented in Barograph.Ingest.Supervisor's moduledoc and README with an explicit bind-address / no-auth warning.

### Issue 5 -- Severity: suggestion

- File: lib/barograph/ingest/graphite.ex:79-88
- Description: Network ingest shares the native write path’s unbounded series
  creation (`resolve_series` inserts into `bg_series` + ETS on first sight of
  each metric/label set). A remote client can therefore grow the SQLite file
  and series cache without bound (unique metric names or tag combinations) even
  when sample volume alone would not trip `:overloaded`. This is inherent to
  the write API, but the new network-facing surface makes it reachable without
  going through application code.
- Suggestion: Document the cardinality risk next to `:ingest` (and that
  file-per-tenant is the isolation model). Consider a future soft limit
  (`:max_series` / reject-new-series under pressure) if ingest remains a
  primary entry point; not blocking for v0.2 if explicitly deferred.
- Status: documented, not implementing a hard limit this pass (matches the reviewer's own "not blocking for v0.2 if explicitly deferred") — cardinality risk and file-per-tenant isolation now called out in Barograph.Ingest.Supervisor's moduledoc and Barograph.open/2's :ingest doc.

### Issue 6 -- Severity: suggestion

- File: test/barograph/ingest/graphite_test.exs:1-109
- Description: E2E coverage is good for basic lines, TCP fragmentation,
  multi-line packets, malformed-line resilience, tags, and multi-connection —
  but gaps remain for behaviour that is easy to regress: (1) `:template` path
  mapping end-to-end (only pure parser tests exist), (2) Graphite second → DB
  `time_unit` conversion when the file is opened with `:millisecond` /
  `:microsecond`, (3) `:max_line_length` enforcement (see Issue 1).
- Suggestion: Add three focused tests: open with
  `template: "*.forklift.metric"` and assert metric/labels; open with
  `time_unit: :millisecond`, send a unix-second line, assert
  `ts == seconds * 1000`; send a line longer than a small `max_line_length`
  and assert connection closed / no sample written.
- Status: fixed — added template end-to-end, time_unit conversion (:millisecond), and max_line_length enforcement (both the simple case and the bypass case) tests to graphite_test.exs.

### Issue 7 -- Severity: suggestion

- File: lib/barograph/ingest/graphite.ex:68-69
- Description: Malformed lines are logged with `inspect(line)` in full.
  Combined with Issue 1 (oversized lines accepted), a client can force
  multi-kilobyte/megabyte log messages per line. Even within the intended 8KiB
  bound, logging full payloads is noisy and may leak sensitive tag values into
  log sinks.
- Suggestion: Log a truncated prefix (e.g. first 120 bytes) plus
  `byte_size(line)`, and avoid logging after oversized-line disconnects beyond
  a one-line warning.
- Status: fixed — malformed-line log now includes byte_size and a binary_part/3-truncated (120 byte) prefix instead of the full inspected line; binary_part used specifically because it stays safe on invalid UTF-8, unlike String.slice/2.

### Issue 8 -- Severity: suggestion

- File: lib/barograph/ingest/supervisor.ex:1-68
- Description: Public configuration surface for Graphite (`:port`,
  `:template`, `:max_line_length`) is only discoverable by reading the private
  `listener_spec/3` implementation (and scattered README/spec prose).
  `Barograph.open/2` points at this module for details, but the moduledoc does
  not list options or defaults (2003 / nil template / 8192).
- Suggestion: Document the `graphite:` keyword options and defaults in
  `Barograph.Ingest.Supervisor`’s moduledoc (and briefly under
  `Barograph.open/2`’s `:ingest` bullet).
- Status: fixed — Barograph.Ingest.Supervisor's moduledoc now documents :port, :template, :max_line_length, :transport_options and their defaults, plus the network-exposure note from Issue 4.

### Issue 9 -- Severity: nit

- File: lib/barograph.ex:61-65
- Description: `close/1` still says it terminates “its writer and read pool.”
  There is no read pool yet, and with v0.2 it also tears down
  `Barograph.Ingest.Supervisor` / the Graphite listener (covered by a test).
- Suggestion: Update the doc to “terminates the database supervisor tree
  (writer, refresher, optional ingest listeners).”
- Status: fixed — Barograph.close/1's doc no longer mentions a nonexistent read pool, and now mentions ingest listener teardown.

### Issue 10 -- Severity: nit

- File: lib/barograph/ingest/graphite/parser.ex:27-34
- Description: `compile_template/1` accepts empty path tokens (e.g.
  `"foo..metric"`, `".metric"`), which become empty-string label keys or odd
  prefix matches. Unlikely in real configs but yields confusing series labels
  rather than a clear `{:error, _}`.
- Suggestion: Reject empty tokens at compile time
  (`{:error, :empty_template_token}`).
- Status: fixed — compile_template/1 rejects any empty token with {:error, :empty_template_token}.

## Suggested fix order

1. README version pin (trivial)
2. `max_line_length` enforcement + tests
3. Binary-safe parser / non-raising nan check + invalid-UTF-8 test
4. Truncated logging
5. Docs for options + bind address
6. Remaining tests (template e2e, time_unit conversion)
7. Cardinality docs / future limit

## Fix pass — 2026-07-21

9 of 10 issues fixed (see per-issue Status above); Issue 5 (network-reachable
unbounded series creation) documented rather than hard-limited, matching the
reviewer's own "not blocking for v0.2 if explicitly deferred." Issue 2's
stated mechanism (String.* raising on invalid UTF-8) did not reproduce on
this project's Elixir 1.19.5 — verified directly before trusting it — but
investigating it surfaced a more severe real bug (Writer GenServer crash via
JSON.encode!), which is what got fixed. All new/changed code covered by
tests; `mix quality` (hex.audit, format, compile --warnings-as-errors,
credo --strict, test, dialyzer) passes clean: 98 tests, 0 failures, 192
mods/funs with no credo issues.
