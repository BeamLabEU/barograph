defmodule BarographTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp db_path(%{tmp_dir: tmp_dir}), do: Path.join(tmp_dir, "test.bg")

  defp raw_query(path, sql) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(statement, [])

    rows =
      Stream.repeatedly(fn -> Exqlite.Sqlite3.step(conn, statement) end)
      |> Stream.take_while(&match?({:row, _}, &1))
      |> Enum.map(fn {:row, row} -> row end)

    :ok = Exqlite.Sqlite3.release(conn, statement)
    :ok = Exqlite.Sqlite3.close(conn)
    rows
  end

  describe "open/2" do
    test "creates and initialises a new database file", context do
      path = db_path(context)
      assert {:ok, db} = Barograph.open(path)
      assert File.exists?(path)
      assert is_pid(GenServer.whereis(db))

      tables =
        raw_query(path, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")

      assert tables == [["bg_events"], ["bg_meta"], ["bg_samples"], ["bg_series"]]
    end

    test "records self-describing metadata", context do
      path = db_path(context)
      assert {:ok, _db} = Barograph.open(path)

      meta = raw_query(path, "SELECT key, value FROM bg_meta") |> Map.new(fn [k, v] -> {k, v} end)

      assert meta["schema_version"] == "1"
      assert meta["time_unit"] == "second"
      assert meta["chunk_interval_seconds"] == "604800"
      assert is_binary(meta["created_with"])
    end

    test "honours a custom time unit at creation", context do
      path = db_path(context)
      assert {:ok, _db} = Barograph.open(path, time_unit: :millisecond)
      assert [["millisecond"]] == raw_query(path, "SELECT value FROM bg_meta WHERE key = 'time_unit'")
    end

    test "reopening an existing database succeeds", context do
      path = db_path(context)
      assert {:ok, db} = Barograph.open(path)
      assert :ok = Barograph.close(db)
      assert {:ok, _db} = Barograph.open(path)
    end

    test "rejects a mismatched time unit on reopen", context do
      path = db_path(context)
      assert {:ok, db} = Barograph.open(path, time_unit: :second)
      assert :ok = Barograph.close(db)

      assert {:error, _reason} = Barograph.open(path, time_unit: :millisecond)
    end

    test "rejects an invalid time unit at creation", context do
      path = db_path(context)
      assert {:error, _reason} = Barograph.open(path, time_unit: :fortnight)
    end

    test "rejects a file written by an incompatible schema version", context do
      path = db_path(context)
      assert {:ok, db} = Barograph.open(path)
      assert :ok = Barograph.close(db)

      {:ok, conn} = Exqlite.Sqlite3.open(path)
      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, "UPDATE bg_meta SET value = '99' WHERE key = 'schema_version'")

      :ok = Exqlite.Sqlite3.bind(statement, [])
      :done = Exqlite.Sqlite3.step(conn, statement)
      :ok = Exqlite.Sqlite3.release(conn, statement)
      :ok = Exqlite.Sqlite3.close(conn)

      assert {:error, _reason} = Barograph.open(path)
    end

    test "opening the same path twice returns the same handle", context do
      path = db_path(context)
      assert {:ok, db} = Barograph.open(path)
      assert {:ok, ^db} = Barograph.open(path)
    end
  end

  describe "close/1" do
    test "terminates the database supervision subtree", context do
      path = db_path(context)
      assert {:ok, db} = Barograph.open(path)
      pid = GenServer.whereis(db)
      assert is_pid(pid)

      assert :ok = Barograph.close(db)
      refute Process.alive?(pid)
    end

    test "closing an unopened database is a no-op" do
      assert :ok =
               Barograph.close({:via, Registry, {Barograph.Registry, {:database, "/nonexistent"}}})
    end
  end

  describe "series cache" do
    test "is created and reachable for an open database", context do
      path = db_path(context)
      assert {:ok, db} = Barograph.open(path)
      assert tid = Barograph.SeriesCache.table(db)

      hash = Barograph.Labels.hash(%{forklift: "FL-07"})
      assert :miss = Barograph.SeriesCache.lookup(tid, "engine_temp", hash)
      assert true = Barograph.SeriesCache.put(tid, "engine_temp", hash, 1)
      assert {:ok, 1} = Barograph.SeriesCache.lookup(tid, "engine_temp", hash)
    end
  end
end
