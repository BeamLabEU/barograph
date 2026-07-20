defmodule Barograph do
  @moduledoc """
  Time-series and event analytics for Elixir, stored in SQLite.

  One file. No server. Full SQL.
  """

  @typedoc """
  A handle to an open Barograph database.

  A `:via` tuple registered in `Barograph.Registry`, usable anywhere a
  GenServer name is accepted.
  """
  @type db :: {:via, Registry, {Barograph.Registry, {:database, String.t()}}}

  @doc """
  Opens (or creates) a Barograph database at `path`.

  If the file does not exist, it is created and initialised with the
  Barograph schema. If it exists and was written by Barograph, its
  metadata is checked and the database is opened. Anything else is
  rejected.

  ## Options

    * `:time_unit` - `:second` (default), `:millisecond`, or `:microsecond`.
      Fixed at creation; must match when reopening an existing database.
    * `:ingest` - keyword list of protocol listeners to start alongside
      this database, e.g. `ingest: [graphite: [port: 2003]]`. Omit for no
      listeners (default — the native `write/4,5` API always works
      regardless). Requires the optional `:thousand_island` dependency.
      See `Barograph.Ingest.Supervisor`.

  ## Examples

      {:ok, db} = Barograph.open("/var/data/metrics.bg")

      {:ok, db} = Barograph.open("/var/data/metrics.bg", ingest: [graphite: [port: 2003]])

  """
  @spec open(Path.t(), keyword()) :: {:ok, db()} | {:error, term()}
  def open(path, opts \\ []) when is_binary(path) do
    key = Path.expand(path)
    name = {:via, Registry, {Barograph.Registry, {:database, key}}}

    child_opts =
      opts
      |> Keyword.put(:path, key)
      |> Keyword.put(:name, name)

    case DynamicSupervisor.start_child(
           Barograph.DatabaseSupervisor,
           {Barograph.Database, child_opts}
         ) do
      {:ok, _pid} -> {:ok, name}
      {:error, {:already_started, _pid}} -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Closes an open database, terminating its writer and read pool.

  The file itself is untouched.
  """
  @spec close(db()) :: :ok
  def close(db) do
    case GenServer.whereis(db) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Barograph.DatabaseSupervisor, pid)
    end
  end

  @doc """
  Writes a single sample, timestamped now in the database's time unit.

      Barograph.write(db, "engine_temp", %{forklift: "FL-07"}, 94.2)

  Returns `{:error, :overloaded}` if the writer's buffer is full
  (spec §7.2); the caller decides whether to drop or retry.
  """
  @spec write(db(), String.t(), map(), number()) :: :ok | {:error, :overloaded}
  def write(db, metric, labels, value) do
    write(db, metric, labels, value, nil)
  end

  @doc """
  Writes a single sample with an explicit timestamp (integer epoch in
  the database's time unit).

  Writes are idempotent: a duplicate `(series, timestamp)` pair
  replaces the previous value (spec §7.5).
  """
  @spec write(db(), String.t(), map(), number(), integer() | nil) ::
          :ok | {:error, :overloaded}
  def write(db, metric, labels, value, ts)
      when is_binary(metric) and is_map(labels) and is_number(value) do
    Barograph.Writer.write(writer(db), metric, labels, value, ts)
  end

  @doc """
  Writes a batch of samples. Each entry is `{metric, labels, value}`
  or `{metric, labels, value, ts}`.
  """
  @spec write_many(db(), [tuple()]) :: :ok | {:error, :overloaded}
  def write_many(db, samples) when is_list(samples) do
    samples =
      Enum.map(samples, fn
        {metric, labels, value} -> {metric, labels, value, nil}
        {metric, labels, value, ts} -> {metric, labels, value, ts}
      end)

    Barograph.Writer.write_many(writer(db), samples)
  end

  @doc """
  Synchronously commits any buffered samples. Rarely needed by callers
  (batching is automatic); useful in tests and before shutdown.
  """
  @spec flush(db()) :: :ok
  def flush(db) do
    Barograph.Writer.flush(writer(db))
  end

  @doc """
  Queries a metric, optionally bucketed and aggregated (spec §9.2 level 1).

      Barograph.query(db, "engine_temp",
        labels: %{forklift: "FL-07"},
        from: ~U[2026-07-01 00:00:00Z],
        to: ~U[2026-07-19 00:00:00Z],
        bucket: {1, :hour},
        agg: :avg
      )

  With `:bucket` (and `:agg`, default `:avg`), returns
  `{:ok, [%{bucket:, value:}, ...]}`. Without `:bucket`, returns raw
  samples as `%{ts, value}` maps. See `Barograph.Query.run/3` for all
  options.
  """
  @spec query(db(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def query(db, metric, opts \\ []) do
    Barograph.Query.run(db, metric, opts)
  end

  @doc """
  Runs raw SQL against the database (spec §9.2 level 3).

  Always available, never second-class: every design decision in
  Barograph keeps the file queryable with plain SQL. Positional
  parameters (`?1`, `?2`, …) are supported. Returns rows as maps of
  column name to value.

      {:ok, rows} = Barograph.sql(db, "SELECT * FROM bg_series")
  """
  @spec sql(db(), String.t(), [term()]) :: {:ok, [%{String.t() => term()}]} | {:error, term()}
  def sql(db, sql, params \\ []) do
    Barograph.SQL.query(db, sql, params)
  end

  @doc "Returns the database's time unit (`:second`, `:millisecond`, or `:microsecond`)."
  @spec time_unit(db()) :: atom()
  def time_unit(db) do
    Barograph.Writer.time_unit(writer(db))
  end

  @doc """
  Creates a continuous aggregate over a metric (spec §8).

      Barograph.create_continuous_aggregate(db, "cpu_1h",
        from: "cpu_usage",
        bucket: {1, :hour},
        refresh_lag: {5, :minute},
        refresh_every: {1, :minute}
      )

  Creates the rollup table `bg_agg_<name>` storing partial aggregate
  state (`count`/`sum`, never `avg`) and registers it for periodic
  watermark-bounded refresh. Query it with plain SQL via `sql/3`.
  """
  @spec create_continuous_aggregate(db(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_continuous_aggregate(db, name, opts) do
    Barograph.Writer.create_aggregate(writer(db), name, opts)
  end

  @doc """
  Forces an immediate refresh of all continuous aggregates. Normally
  handled by the refresher on each aggregate's `:refresh_every`
  interval; useful in tests and after bulk imports.
  """
  @spec refresh_aggregates(db()) :: :ok
  def refresh_aggregates(db) do
    Barograph.Writer.refresh_aggregates(writer(db))
  end

  defp writer({:via, Registry, {Barograph.Registry, {:database, key}}}),
    do: {:via, Registry, {Barograph.Registry, {:writer, key}}}
end
