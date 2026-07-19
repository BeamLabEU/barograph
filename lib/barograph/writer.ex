defmodule Barograph.Writer do
  @moduledoc """
  Owns the single write connection to a Barograph database (spec §7.1).

  Applies the connection pragmas, runs schema migrations on startup, and
  warms the series cache. Batching and back-pressure (spec §7.2) are
  added on top of this skeleton in the write-path milestone.
  """

  use GenServer

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    db = Keyword.fetch!(opts, :db)

    with {:ok, conn} <- Exqlite.Sqlite3.open(path),
         :ok <- pragmas(conn),
         {:ok, meta} <- Barograph.Schema.migrate(conn, opts) do
      :ok = warm_series_cache(db, conn)
      {:ok, %{conn: conn, path: path, db: db, meta: meta}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn}) do
    :ok = Exqlite.Sqlite3.close(conn)
    :ok
  end

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
    case Barograph.SeriesCache.table(db) do
      nil ->
        :ok

      tid ->
        {:ok, statement} =
          Exqlite.Sqlite3.prepare(conn, "SELECT metric, labels_hash, id FROM bg_series")

        :ok = Exqlite.Sqlite3.bind(statement, [])

        Stream.repeatedly(fn -> Exqlite.Sqlite3.step(conn, statement) end)
        |> Stream.take_while(&match?({:row, _}, &1))
        |> Enum.each(fn {:row, [metric, labels_hash, id]} ->
          Barograph.SeriesCache.put(tid, metric, labels_hash, id)
        end)

        :ok = Exqlite.Sqlite3.release(conn, statement)
        :ok
    end
  end
end
