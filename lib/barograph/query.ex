defmodule Barograph.Query do
  @moduledoc """
  Generated SQL for time-bucketed queries (spec §9.1).

  Elixir functions returning SQL fragments — no C extension, no custom
  query language. Level 1 of the query layer: the common case as a
  single call. Everything here degrades gracefully to level 3 — the
  generated SQL is plain SQLite, runnable by hand.
  """

  alias Barograph.SQL

  @aggregates ~w(avg min max sum count)a
  @bucket_seconds %{second: 1, minute: 60, hour: 3_600, day: 86_400, week: 604_800}
  @unit_factor %{second: 1, millisecond: 1_000, microsecond: 1_000_000}

  @doc """
  Runs a bucketed aggregate query against a metric (spec §9.2 level 1).

  ## Options

    * `:labels` - label filter map; matched with `json_extract` on the
      series' labels. A series matches if it carries at least the given
      pairs.
    * `:from`, `:to` - `DateTime` or integer epoch in the database's
      time unit. `from` is inclusive, `to` exclusive.
    * `:bucket` - `{n, unit}` where unit is `:second`, `:minute`,
      `:hour`, `:day`, or `:week`. Required when `:agg` is given.
    * `:agg` - one of `:avg`, `:min`, `:max`, `:sum`, `:count`.

  Without `:bucket`, returns raw samples as `%{ts, value}` maps, ordered
  by time. With `:bucket`, returns `%{bucket, value}` maps where
  `bucket` is the bucket start epoch in the database's time unit.
  """
  @spec run(Barograph.db(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def run(db, metric, opts) do
    time_unit = Barograph.Writer.time_unit(writer(db))

    with {:ok, sql, params} <- build(metric, opts, time_unit),
         {:ok, rows} <- SQL.query(db, sql, params) do
      # Columns are only ever :ts, :bucket, :value — existing atoms.
      {:ok, Enum.map(rows, &Map.new(&1, fn {k, v} -> {String.to_existing_atom(k), v} end))}
    end
  end

  @doc """
  The `time_bucket` hyperfunction as a SQL fragment (spec §9.1):
  integer division and multiply on epoch timestamps.
  """
  @spec time_bucket(String.t(), pos_integer()) :: String.t()
  def time_bucket(ts_expr, width) when is_integer(width) and width > 0 do
    "(#{ts_expr} / #{width}) * #{width}"
  end

  @doc "Bucket width of `{n, unit}` expressed in the database's time unit."
  @spec bucket_width({pos_integer(), atom()}, atom()) :: pos_integer()
  def bucket_width({n, unit}, time_unit) when is_integer(n) and n > 0 do
    n * Map.fetch!(@bucket_seconds, unit) * Map.fetch!(@unit_factor, time_unit)
  end

  defp build(metric, opts, time_unit) do
    with :ok <- check_bucket(opts),
         :ok <- check_agg(opts) do
      {where, params} = where_clause(metric, opts, time_unit)

      case Keyword.get(opts, :bucket) do
        nil ->
          sql = """
          SELECT s.ts AS ts, s.value AS value
          FROM bg_samples s
          JOIN bg_series r ON r.id = s.series_id
          WHERE #{where}
          ORDER BY s.ts
          """

          {:ok, sql, params}

        bucket ->
          width = bucket_width(bucket, time_unit)
          agg = opts |> Keyword.get(:agg, :avg) |> Atom.to_string() |> String.upcase()

          sql = """
          SELECT #{time_bucket("s.ts", width)} AS bucket, #{agg}(s.value) AS value
          FROM bg_samples s
          JOIN bg_series r ON r.id = s.series_id
          WHERE #{where}
          GROUP BY bucket
          ORDER BY bucket
          """

          {:ok, sql, params}
      end
    end
  end

  defp where_clause(metric, opts, time_unit) do
    {label_clauses, label_params} =
      opts
      |> Keyword.get(:labels, %{})
      |> Enum.map(fn {key, value} ->
        {"json_extract(r.labels, ?) = ?", ["$.#{key}", to_string(value)]}
      end)
      |> Enum.unzip()

    clauses = ["r.metric = ?" | label_clauses]
    params = [metric | List.flatten(label_params)]

    {clauses, params} =
      case Keyword.get(opts, :from) do
        nil -> {clauses, params}
        from -> {clauses ++ ["s.ts >= ?"], params ++ [to_epoch(from, time_unit)]}
      end

    {clauses, params} =
      case Keyword.get(opts, :to) do
        nil -> {clauses, params}
        to -> {clauses ++ ["s.ts < ?"], params ++ [to_epoch(to, time_unit)]}
      end

    {Enum.join(clauses, " AND "), params}
  end

  defp to_epoch(%DateTime{} = dt, time_unit), do: DateTime.to_unix(dt, time_unit)
  defp to_epoch(ts, _time_unit) when is_integer(ts), do: ts

  defp check_bucket(opts) do
    case Keyword.get(opts, :bucket) do
      nil -> :ok
      {n, unit} when is_integer(n) and n > 0 and is_map_key(@bucket_seconds, unit) -> :ok
      other -> {:error, {:invalid_bucket, other}}
    end
  end

  defp check_agg(opts) do
    case Keyword.get(opts, :agg, :avg) do
      agg when agg in @aggregates -> :ok
      other -> {:error, {:invalid_aggregate, other}}
    end
  end

  defp writer({:via, Registry, {Barograph.Registry, {:database, key}}}),
    do: {:via, Registry, {Barograph.Registry, {:writer, key}}}
end
