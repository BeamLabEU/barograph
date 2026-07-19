defmodule Barograph.Writer do
  @moduledoc """
  Owns the single write connection to a Barograph database (spec §7).

  All writes funnel through this one process. Incoming samples are
  buffered and committed in a single transaction when either
  `:batch_size` samples are buffered or `:batch_timeout` milliseconds
  have elapsed — whichever comes first (spec §7.2). If the buffer grows
  beyond `:max_buffer`, writes are rejected with `{:error, :overloaded}`
  rather than growing without bound.
  """

  use GenServer

  require Logger

  alias Barograph.{Labels, SeriesCache}

  @default_batch_size 1_000
  @default_batch_timeout 100
  @default_max_buffer 50_000

  # Rows per multi-row INSERT statement; 3 parameters each, far below
  # SQLITE_MAX_VARIABLE_NUMBER.
  @insert_rows_per_statement 500

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = writer_name(Keyword.fetch!(opts, :db))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Buffers a single sample for the next batch commit."
  @spec write(GenServer.name(), String.t(), map(), number(), integer() | nil) ::
          :ok | {:error, :overloaded}
  def write(writer, metric, labels, value, ts) do
    GenServer.call(writer, {:write, [{metric, labels, value, ts}]})
  end

  @doc "Buffers a list of `{metric, labels, value, ts}` samples."
  @spec write_many(GenServer.name(), [{String.t(), map(), number(), integer() | nil}]) ::
          :ok | {:error, :overloaded}
  def write_many(writer, samples) when is_list(samples) do
    GenServer.call(writer, {:write, samples})
  end

  @doc "Synchronously commits any buffered samples."
  @spec flush(GenServer.name()) :: :ok
  def flush(writer) do
    GenServer.call(writer, :flush)
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    db = Keyword.fetch!(opts, :db)

    with {:ok, conn} <- Exqlite.Sqlite3.open(path),
         :ok <- pragmas(conn),
         {:ok, meta} <- Barograph.Schema.migrate(conn, opts),
         {:ok, insert_series} <-
           Exqlite.Sqlite3.prepare(
             conn,
             "INSERT OR IGNORE INTO bg_series (metric, labels_hash, labels, created_at) " <>
               "VALUES (?1, ?2, ?3, ?4)"
           ),
         {:ok, select_series} <-
           Exqlite.Sqlite3.prepare(
             conn,
             "SELECT id FROM bg_series WHERE metric = ?1 AND labels_hash = ?2"
           ) do
      :ok = warm_series_cache(db, conn)

      {:ok,
       %{
         conn: conn,
         db: db,
         time_unit: time_unit(meta),
         insert_series: insert_series,
         select_series: select_series,
         buffer: [],
         buffer_size: 0,
         batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
         batch_timeout: Keyword.get(opts, :batch_timeout, @default_batch_timeout),
         max_buffer: Keyword.get(opts, :max_buffer, @default_max_buffer)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:write, samples}, _from, state) do
    if state.buffer_size + length(samples) > state.max_buffer do
      {:reply, {:error, :overloaded}, state}
    else
      state = Enum.reduce(samples, state, &buffer_sample(&2, &1))
      state = if state.buffer_size >= state.batch_size, do: do_flush(state), else: state
      {:reply, :ok, state}
    end
  end

  def handle_call(:flush, _from, state) do
    {:reply, :ok, do_flush(state)}
  end

  @impl true
  def handle_info(:flush, state) do
    {:noreply, do_flush(state)}
  end

  @impl true
  def terminate(_reason, state) do
    _ = do_flush(state)
    :ok = Exqlite.Sqlite3.close(state.conn)
    :ok
  end

  ## Buffering

  defp buffer_sample(state, {metric, labels, value, ts}) do
    series_id = resolve_series(state, metric, labels)
    ts = ts || System.os_time(state.time_unit)

    state = %{state | buffer: [{series_id, ts, value} | state.buffer], buffer_size: state.buffer_size + 1}

    if state.buffer_size == 1 do
      Process.send_after(self(), :flush, state.batch_timeout)
    end

    state
  end

  defp do_flush(%{buffer_size: 0} = state), do: state

  defp do_flush(state) do
    %{conn: conn} = state

    with :ok <- Exqlite.Sqlite3.execute(conn, "BEGIN") do
      # The buffer accumulates newest-first; commit in arrival order so
      # that on (series, ts) conflicts the latest write wins.
      rows = Enum.reverse(state.buffer)

      # One multi-row INSERT per flush: a single statement parse and one
      # NIF round-trip instead of three calls per row.
      result =
        rows
        |> Enum.chunk_every(@insert_rows_per_statement)
        |> Enum.reduce_while(:ok, fn chunk, :ok ->
          case insert_rows(conn, chunk) do
            :done -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        :ok ->
          :ok = Exqlite.Sqlite3.execute(conn, "COMMIT")

        {:error, reason} ->
          :ok = Exqlite.Sqlite3.execute(conn, "ROLLBACK")
          Logger.error("barograph: batch commit failed, dropped #{state.buffer_size} samples: #{inspect(reason)}")
      end
    end

    %{state | buffer: [], buffer_size: 0}
  end

  ## Series resolution (spec §7.4 — the write path never joins)

  # INSERT OR REPLACE on the (series_id, ts) primary key makes writes
  # idempotent and accepts late/out-of-order data (spec §7.5).
  defp insert_rows(conn, rows) do
    placeholders = Enum.map_join(rows, ",", fn _ -> "(?, ?, ?)" end)
    sql = "INSERT OR REPLACE INTO bg_samples (series_id, ts, value) VALUES " <> placeholders
    params = Enum.flat_map(rows, fn {series_id, ts, value} -> [series_id, ts, value] end)

    with {:ok, statement} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- Exqlite.Sqlite3.bind(statement, params) do
      result = Exqlite.Sqlite3.step(conn, statement)
      :ok = Exqlite.Sqlite3.release(conn, statement)
      result
    end
  end

  defp resolve_series(state, metric, labels) do
    labels_hash = Labels.hash(labels)
    tid = SeriesCache.table(state.db)

    case tid && SeriesCache.lookup(tid, metric, labels_hash) do
      {:ok, series_id} ->
        series_id

      _ ->
        series_id = insert_series(state, metric, labels, labels_hash)
        if tid, do: SeriesCache.put(tid, metric, labels_hash, series_id)
        series_id
    end
  end

  defp insert_series(state, metric, labels, labels_hash) do
    %{conn: conn, insert_series: insert, select_series: select} = state
    created_at = System.os_time(:second)

    :ok = Exqlite.Sqlite3.bind(insert, [metric, {:blob, labels_hash}, JSON.encode!(labels), created_at])
    :done = Exqlite.Sqlite3.step(conn, insert)
    :ok = Exqlite.Sqlite3.reset(insert)

    :ok = Exqlite.Sqlite3.bind(select, [metric, {:blob, labels_hash}])
    {:row, [series_id]} = Exqlite.Sqlite3.step(conn, select)
    :ok = Exqlite.Sqlite3.reset(select)

    series_id
  end

  ## Startup

  # Spec §7.3. synchronous = NORMAL under WAL risks losing the last
  # transaction on power loss, not corruption — the right trade for
  # metrics. auto_vacuum is handled in Schema, before table creation.
  defp pragmas(conn) do
    with :ok <- Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode = WAL"),
         :ok <- Exqlite.Sqlite3.execute(conn, "PRAGMA synchronous = NORMAL"),
         :ok <- Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout = 5000"),
         :ok <- Exqlite.Sqlite3.execute(conn, "PRAGMA foreign_keys = ON") do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp warm_series_cache(db, conn) do
    case SeriesCache.table(db) do
      nil ->
        :ok

      tid ->
        {:ok, statement} =
          Exqlite.Sqlite3.prepare(conn, "SELECT metric, labels_hash, id FROM bg_series")

        :ok = Exqlite.Sqlite3.bind(statement, [])

        Stream.repeatedly(fn -> Exqlite.Sqlite3.step(conn, statement) end)
        |> Stream.take_while(&match?({:row, _}, &1))
        |> Enum.each(fn {:row, [metric, labels_hash, id]} ->
          SeriesCache.put(tid, metric, labels_hash, id)
        end)

        :ok = Exqlite.Sqlite3.release(conn, statement)
        :ok
    end
  end

  defp time_unit(%{"time_unit" => unit}), do: String.to_existing_atom(unit)

  defp writer_name({:via, Registry, {Barograph.Registry, {:database, key}}}),
    do: {:via, Registry, {Barograph.Registry, {:writer, key}}}
end
