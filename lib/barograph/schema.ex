defmodule Barograph.Schema do
  @moduledoc """
  DDL and metadata for a Barograph database file.

  A Barograph file is self-describing: `bg_meta` records the schema
  version, time unit, and the library version that created the file.
  Opening a file written by an incompatible version is a checked
  operation, not a hope.
  """

  @schema_version "1"
  @chunk_interval_seconds "604800"

  @time_units [:second, :millisecond, :microsecond]

  @doc "The schema version this library writes."
  def schema_version, do: @schema_version

  @doc "Valid time units for a database, fixed at creation."
  def time_units, do: @time_units

  @doc """
  Initialises a fresh database or validates an existing one.

  Runs against a raw `Exqlite.Sqlite3` connection. Returns the database
  metadata as a map on success.

  Options:

    * `:time_unit` - required for creation; ignored (but validated, if
      given) when opening an existing database.

  """
  @spec migrate(Exqlite.Sqlite3.db(), keyword()) :: {:ok, map()} | {:error, term()}
  def migrate(conn, opts) do
    if initialised?(conn) do
      validate(conn, opts)
    else
      create(conn, opts)
    end
  end

  defp initialised?(conn) do
    {:ok, statement} =
      Exqlite.Sqlite3.prepare(
        conn,
        "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'bg_meta'"
      )

    :ok = Exqlite.Sqlite3.bind(statement, [])
    {:row, [count]} = Exqlite.Sqlite3.step(conn, statement)
    :ok = Exqlite.Sqlite3.release(conn, statement)
    count == 1
  end

  defp create(conn, opts) do
    time_unit = Keyword.get(opts, :time_unit, :second)

    if time_unit in @time_units do
      :ok = execute_batch(conn, ddl())

      meta = %{
        "schema_version" => @schema_version,
        "time_unit" => Atom.to_string(time_unit),
        "chunk_interval_seconds" => @chunk_interval_seconds,
        "created_with" => library_version()
      }

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, "INSERT INTO bg_meta (key, value) VALUES (?1, ?2)")

      Enum.each(meta, fn {key, value} ->
        :ok = Exqlite.Sqlite3.bind(statement, [key, value])
        :done = Exqlite.Sqlite3.step(conn, statement)
        :ok = Exqlite.Sqlite3.reset(statement)
      end)

      :ok = Exqlite.Sqlite3.release(conn, statement)
      {:ok, meta}
    else
      {:error, {:invalid_time_unit, time_unit}}
    end
  end

  defp validate(conn, opts) do
    with {:ok, meta} <- read_meta(conn),
         :ok <- check_schema_version(meta),
         :ok <- check_time_unit(meta, opts) do
      {:ok, meta}
    end
  end

  defp read_meta(conn) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "SELECT key, value FROM bg_meta")
    :ok = Exqlite.Sqlite3.bind(statement, [])

    with {:ok, rows} <- Barograph.Rows.fetch_all(conn, statement) do
      :ok = Exqlite.Sqlite3.release(conn, statement)
      {:ok, Map.new(rows, fn [key, value] -> {key, value} end)}
    end
  end

  defp check_schema_version(%{"schema_version" => @schema_version}), do: :ok

  defp check_schema_version(%{"schema_version" => other}),
    do: {:error, {:unsupported_schema_version, other}}

  defp check_schema_version(_meta), do: {:error, :missing_schema_version}

  defp check_time_unit(%{"time_unit" => unit}, opts) do
    case Keyword.get(opts, :time_unit) do
      nil ->
        :ok

      requested ->
        if Atom.to_string(requested) == unit do
          :ok
        else
          {:error, {:time_unit_mismatch, expected: String.to_atom(unit), got: requested}}
        end
    end
  end

  defp execute_batch(conn, sql) do
    case Exqlite.Sqlite3.execute(conn, sql) do
      :ok -> :ok
      {:error, reason} -> raise "failed to initialise Barograph schema: #{inspect(reason)}"
    end
  end

  defp library_version do
    case Application.spec(:barograph, :vsn) do
      nil -> "dev"
      vsn -> List.to_string(vsn)
    end
  end

  defp ddl do
    # auto_vacuum must be set before the first table is created; it is a
    # no-op on an already-initialised database.
    """
    PRAGMA auto_vacuum = INCREMENTAL;

    CREATE TABLE bg_meta (
      key    TEXT PRIMARY KEY,
      value  TEXT NOT NULL
    ) STRICT;

    CREATE TABLE bg_series (
      id           INTEGER PRIMARY KEY,
      metric       TEXT NOT NULL,
      labels_hash  BLOB NOT NULL,
      labels       TEXT NOT NULL,
      created_at   INTEGER NOT NULL,
      UNIQUE (metric, labels_hash)
    ) STRICT;

    CREATE INDEX bg_series_metric ON bg_series (metric);

    CREATE TABLE bg_samples (
      series_id  INTEGER NOT NULL,
      ts         INTEGER NOT NULL,
      value      REAL NOT NULL,
      PRIMARY KEY (series_id, ts)
    ) STRICT, WITHOUT ROWID;

    CREATE TABLE bg_events (
      series_id  INTEGER NOT NULL,
      ts         INTEGER NOT NULL,
      payload    TEXT NOT NULL,
      PRIMARY KEY (series_id, ts)
    ) STRICT, WITHOUT ROWID;

    CREATE TABLE bg_agg_meta (
      name           TEXT PRIMARY KEY,
      source         TEXT NOT NULL,
      bucket_width   INTEGER NOT NULL,
      watermark      INTEGER NOT NULL,
      lag            INTEGER NOT NULL,
      refresh_every  INTEGER NOT NULL
    ) STRICT;

    CREATE TABLE bg_agg_invalid (
      name    TEXT NOT NULL,
      bucket  INTEGER NOT NULL,
      PRIMARY KEY (name, bucket)
    ) STRICT, WITHOUT ROWID;
    """
  end
end
