defmodule Barograph.Aggregate do
  @moduledoc """
  Continuous aggregates: partial state, watermark refresh, invalidation
  (spec §8).

  Aggregates store `count`/`sum`, never `avg` — the rule that makes
  hierarchical rollups compose and re-aggregation over arbitrary windows
  stay correct (§8.2). Refresh aggregates only `(watermark, now - lag]`
  and upserts, so the cost is proportional to new data, not total data
  (§8.3). Late samples below the watermark mark their bucket dirty in
  `bg_agg_invalid` and the next refresh recomputes it (§8.4).

  Known v0.1 limitation: `sum_dt`/`sum_v_dt` (time-weighted average
  state) are computed from intervals within the refreshed window only —
  the interval between the last sample before a window and its first
  sample inside is not counted.
  """

  @name_format ~r/^[a-z][a-z0-9_]{0,62}$/

  @bucket_seconds %{second: 1, minute: 60, hour: 3_600, day: 86_400, week: 604_800}
  @unit_factor %{second: 1, millisecond: 1_000, microsecond: 1_000_000}

  @typedoc """
  Aggregate definition, one row of `bg_agg_meta`.

  `bucket_width`, `watermark`, and `lag` are in the database's time
  unit; `refresh_every` is in milliseconds (it is a scheduling
  interval, not a timestamp).
  """
  @type definition :: %{
          name: String.t(),
          source: String.t(),
          bucket_width: pos_integer(),
          watermark: integer(),
          lag: non_neg_integer(),
          refresh_every: pos_integer()
        }

  @doc """
  Creates the rollup table `bg_agg_<name>` and registers the aggregate
  in `bg_agg_meta`. The watermark starts at zero, so the first refresh
  backfills all existing data up to `now - lag` (Timescale behaviour).
  """
  @spec create(:exqlite.conn(), String.t(), keyword(), atom()) :: :ok | {:error, term()}
  def create(conn, name, opts, time_unit) do
    with :ok <- check_name(name),
         :ok <- check_absent(conn, name),
         {:ok, bucket_width} <- fetch_width(opts, :bucket, time_unit, 1),
         {:ok, lag} <- fetch_width(opts, :refresh_lag, time_unit, 0),
         {:ok, refresh_every_ms} <- fetch_width(opts, :refresh_every, :millisecond, 1),
         source when is_binary(source) <- Keyword.get(opts, :from) do
      :ok = Exqlite.Sqlite3.execute(conn, table_ddl(name))

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, """
        INSERT INTO bg_agg_meta (name, source, bucket_width, watermark, lag, refresh_every)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        """)

      :ok =
        Exqlite.Sqlite3.bind(statement, [name, source, bucket_width, 0, lag, refresh_every_ms])

      :done = Exqlite.Sqlite3.step(conn, statement)
      :ok = Exqlite.Sqlite3.release(conn, statement)
      :ok
    else
      nil -> {:error, {:missing_option, :from}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "All registered aggregate definitions."
  @spec definitions(:exqlite.conn()) :: [definition()]
  def definitions(conn) do
    {:ok, statement} =
      Exqlite.Sqlite3.prepare(
        conn,
        "SELECT name, source, bucket_width, watermark, lag, refresh_every FROM bg_agg_meta"
      )

    :ok = Exqlite.Sqlite3.bind(statement, [])

    defs =
      conn
      |> Barograph.Rows.fetch_all!(statement)
      |> Enum.map(fn [name, source, bucket_width, watermark, lag, refresh_every] ->
        %{
          name: name,
          source: source,
          bucket_width: bucket_width,
          watermark: watermark,
          lag: lag,
          refresh_every: refresh_every
        }
      end)

    :ok = Exqlite.Sqlite3.release(conn, statement)
    defs
  end

  @doc """
  Refreshes one aggregate: recomputes invalidated buckets below the
  watermark, then finalises buckets up to `now - lag`. Idempotent and
  crash-safe — rerunning after a failure redoes the same work.

  The aggregated range is `[watermark, upper)` — exclusive at the top,
  so a sample exactly at `upper` stays in its (not yet complete) bucket
  and is picked up by a later refresh.
  """
  @spec refresh(:exqlite.conn(), definition(), integer()) :: :ok
  def refresh(conn, defn, now) do
    %{name: name, bucket_width: width, watermark: watermark, lag: lag} = defn
    upper = div(now - lag, width) * width

    :ok = Exqlite.Sqlite3.execute(conn, "BEGIN")
    :ok = recompute_invalid_buckets(conn, defn)

    if upper > watermark do
      :ok = aggregate_range(conn, defn, watermark, upper)
      :ok = set_watermark(conn, name, upper)
    end

    :ok = Exqlite.Sqlite3.execute(conn, "COMMIT")
    :ok
  end

  @doc """
  Marks dirty buckets for late-arriving samples (spec §8.4): one row in
  `bg_agg_invalid` per affected aggregate and bucket. `rows` are
  `{series_id, ts}` pairs from a just-committed batch.
  """
  @spec mark_invalidations(:exqlite.conn(), [{integer(), integer()}]) :: :ok
  def mark_invalidations(_conn, []), do: :ok

  def mark_invalidations(conn, rows) do
    rows
    |> Enum.chunk_every(500)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      values = Enum.map_join(chunk, ",", fn {series_id, ts} -> "(#{series_id}, #{ts})" end)

      case Exqlite.Sqlite3.execute(conn, """
           WITH batch (series_id, ts) AS (VALUES #{values})
           INSERT OR IGNORE INTO bg_agg_invalid (name, bucket)
           SELECT m.name, (batch.ts / m.bucket_width) * m.bucket_width
           FROM batch
           JOIN bg_series r ON r.id = batch.series_id
           JOIN bg_agg_meta m ON m.source = r.metric
           WHERE batch.ts <= m.watermark
           """) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  ## Internals

  defp recompute_invalid_buckets(conn, %{name: name} = defn) do
    {:ok, statement} =
      Exqlite.Sqlite3.prepare(conn, "SELECT bucket FROM bg_agg_invalid WHERE name = ?1")

    :ok = Exqlite.Sqlite3.bind(statement, [name])

    buckets =
      conn
      |> Barograph.Rows.fetch_all!(statement)
      |> Enum.map(fn [bucket] -> bucket end)

    :ok = Exqlite.Sqlite3.release(conn, statement)

    Enum.each(buckets, fn bucket ->
      :ok = execute_with(conn, "DELETE FROM #{table_name(name)} WHERE bucket = ?1", [bucket])
      :ok = aggregate_range(conn, defn, bucket, bucket + defn.bucket_width)

      :ok =
        execute_with(conn, "DELETE FROM bg_agg_invalid WHERE name = ?1 AND bucket = ?2", [
          name,
          bucket
        ])
    end)

    :ok
  end

  # Partial aggregate state over [from, to) — count/sum, never avg.
  # first_val/last_val come from window functions over the bucket; dt is
  # the interval to the previous sample, for time-weighted averages.
  defp aggregate_range(conn, %{name: name, source: source, bucket_width: width}, from, to) do
    sql = """
    INSERT OR REPLACE INTO #{table_name(name)}
      (bucket, series_id, count, sum, min, max, first_ts, first_val, last_ts, last_val, sum_dt, sum_v_dt)
    WITH w AS (
      SELECT s.series_id AS series_id,
             (s.ts / #{width}) * #{width} AS bucket,
             s.ts AS ts,
             s.value AS value,
             s.ts - LAG(s.ts) OVER (PARTITION BY s.series_id ORDER BY s.ts) AS dt,
             FIRST_VALUE(s.value) OVER (
               PARTITION BY s.series_id, (s.ts / #{width}) * #{width} ORDER BY s.ts
             ) AS first_val,
             LAST_VALUE(s.value) OVER (
               PARTITION BY s.series_id, (s.ts / #{width}) * #{width} ORDER BY s.ts
               ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
             ) AS last_val
      FROM bg_samples s
      JOIN bg_series r ON r.id = s.series_id
      WHERE r.metric = ?1 AND s.ts >= ?2 AND s.ts < ?3
    )
    SELECT bucket, series_id,
           COUNT(*), SUM(value), MIN(value), MAX(value),
           MIN(ts), MAX(first_val), MAX(ts), MAX(last_val),
           COALESCE(SUM(dt), 0), COALESCE(SUM(value * dt), 0)
    FROM w
    GROUP BY series_id, bucket
    """

    execute_with(conn, sql, [source, from, to])
  end

  defp set_watermark(conn, name, watermark) do
    execute_with(conn, "UPDATE bg_agg_meta SET watermark = ?1 WHERE name = ?2", [watermark, name])
  end

  defp execute_with(conn, sql, params) do
    with {:ok, statement} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- Exqlite.Sqlite3.bind(statement, params),
         :done <- Exqlite.Sqlite3.step(conn, statement) do
      :ok = Exqlite.Sqlite3.release(conn, statement)
      :ok
    end
  end

  defp check_name(name) do
    if is_binary(name) and Regex.match?(@name_format, name) do
      :ok
    else
      {:error, {:invalid_aggregate_name, name}}
    end
  end

  defp check_absent(conn, name) do
    case table_exists?(conn, table_name(name)) do
      true -> {:error, {:aggregate_exists, name}}
      false -> :ok
    end
  end

  defp table_exists?(conn, table) do
    {:ok, statement} =
      Exqlite.Sqlite3.prepare(
        conn,
        "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?1"
      )

    :ok = Exqlite.Sqlite3.bind(statement, [table])
    {:row, [count]} = Exqlite.Sqlite3.step(conn, statement)
    :ok = Exqlite.Sqlite3.release(conn, statement)
    count == 1
  end

  defp fetch_width(opts, key, time_unit, min) do
    case Keyword.get(opts, key) do
      nil ->
        {:error, {:missing_option, key}}

      {n, unit} when is_integer(n) and n >= min and is_map_key(@bucket_seconds, unit) ->
        {:ok, n * Map.fetch!(@bucket_seconds, unit) * Map.fetch!(@unit_factor, time_unit)}

      _other ->
        {:error, {:invalid_width, key}}
    end
  end

  defp table_name(name), do: "bg_agg_#{name}"

  # Spec §8.1 partial aggregate state.
  defp table_ddl(name) do
    """
    CREATE TABLE #{table_name(name)} (
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
      sum_dt     REAL NOT NULL,
      sum_v_dt   REAL NOT NULL,
      PRIMARY KEY (series_id, bucket)
    ) STRICT, WITHOUT ROWID
    """
  end
end
