defmodule Barograph.WriterTest do
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

  describe "write/5" do
    test "persists a sample and its series", context do
      path = db_path(context)
      {:ok, db} = Barograph.open(path)

      assert :ok = Barograph.write(db, "engine_temp", %{forklift: "FL-07"}, 94.2, 1_752_931_200)
      assert :ok = Barograph.flush(db)

      assert [[1, 1_752_931_200, 94.2]] =
               raw_query(path, "SELECT series_id, ts, value FROM bg_samples")

      assert [[1, "engine_temp", ~s({"forklift":"FL-07"})]] =
               raw_query(path, "SELECT id, metric, labels FROM bg_series")
    end

    test "timestamps with the database time unit when ts is omitted", context do
      path = db_path(context)
      {:ok, db} = Barograph.open(path, time_unit: :millisecond)

      before = System.os_time(:millisecond)
      assert :ok = Barograph.write(db, "m", %{}, 1.0)
      assert :ok = Barograph.flush(db)

      [[_sid, ts, _v]] = raw_query(path, "SELECT series_id, ts, value FROM bg_samples")
      assert ts >= before
      assert ts <= System.os_time(:millisecond)
    end

    test "is idempotent on (series, ts) — latest write wins", context do
      path = db_path(context)
      {:ok, db} = Barograph.open(path)

      assert :ok = Barograph.write(db, "m", %{a: "1"}, 1.0, 100)
      assert :ok = Barograph.write(db, "m", %{a: "1"}, 2.0, 100)
      assert :ok = Barograph.flush(db)

      assert [[100, 2.0]] = raw_query(path, "SELECT ts, value FROM bg_samples")
    end

    test "accepts out-of-order timestamps", context do
      path = db_path(context)
      {:ok, db} = Barograph.open(path)

      assert :ok = Barograph.write(db, "m", %{}, 1.0, 300)
      assert :ok = Barograph.write(db, "m", %{}, 2.0, 100)
      assert :ok = Barograph.write(db, "m", %{}, 3.0, 200)
      assert :ok = Barograph.flush(db)

      assert [[100, 2.0], [200, 3.0], [300, 1.0]] =
               raw_query(path, "SELECT ts, value FROM bg_samples ORDER BY ts")
    end

    test "reuses the series id for repeated label sets", context do
      path = db_path(context)
      {:ok, db} = Barograph.open(path)

      for ts <- 1..5 do
        assert :ok = Barograph.write(db, "m", %{a: "1"}, ts * 1.0, ts)
      end

      assert :ok = Barograph.flush(db)
      assert [[5]] = raw_query(path, "SELECT count(*) FROM bg_samples")
      assert [[1]] = raw_query(path, "SELECT count(*) FROM bg_series")
    end
  end

  describe "write_many/2" do
    test "persists a mixed batch of 3- and 4-tuples", context do
      path = db_path(context)
      {:ok, db} = Barograph.open(path)

      assert :ok =
               Barograph.write_many(db, [
                 {"a", %{x: "1"}, 1.0, 10},
                 {"a", %{x: "1"}, 2.0},
                 {"b", %{}, 3.0, 30}
               ])

      assert :ok = Barograph.flush(db)
      assert [[3]] = raw_query(path, "SELECT count(*) FROM bg_samples")
      assert [[2]] = raw_query(path, "SELECT count(*) FROM bg_series")
    end
  end

  describe "batching" do
    test "commits automatically at batch_size", context do
      path = db_path(context)
      {:ok, db} = Barograph.open(path, batch_size: 10, batch_timeout: 60_000)

      for ts <- 1..10, do: Barograph.write(db, "m", %{}, ts * 1.0, ts)

      # No explicit flush — the batch size triggered the commit.
      assert [[10]] = raw_query(path, "SELECT count(*) FROM bg_samples")
    end

    test "commits automatically after batch_timeout", context do
      path = db_path(context)
      {:ok, db} = Barograph.open(path, batch_size: 1_000, batch_timeout: 20)

      assert :ok = Barograph.write(db, "m", %{}, 1.0, 1)
      Process.sleep(100)

      assert [[1]] = raw_query(path, "SELECT count(*) FROM bg_samples")
    end
  end

  describe "back-pressure" do
    test "returns {:error, :overloaded} beyond max_buffer", context do
      path = db_path(context)
      {:ok, db} = Barograph.open(path, max_buffer: 5, batch_timeout: 60_000)

      for ts <- 1..5, do: Barograph.write(db, "m", %{}, ts * 1.0, ts)

      assert {:error, :overloaded} = Barograph.write(db, "m", %{}, 6.0, 6)

      assert {:error, :overloaded} =
               Barograph.write_many(db, [{"m", %{}, 7.0, 7}])
    end
  end
end
