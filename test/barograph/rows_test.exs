defmodule Barograph.RowsTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # A statement that yields two good rows and then hits a genuine
  # mid-scan SQLite error. Malformed JSON is a portable, deterministic
  # way to force `step/2` to return `{:error, _}` after it has already
  # returned rows.
  defp failing_statement do
    {:ok, conn} = Exqlite.Sqlite3.open(":memory:")
    :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE t (v TEXT)")
    {:ok, ins} = Exqlite.Sqlite3.prepare(conn, "INSERT INTO t VALUES (?1)")

    for v <- [~s({"a":1}), ~s({"a":2}), "not valid json", ~s({"a":4})] do
      :ok = Exqlite.Sqlite3.bind(ins, [v])
      :done = Exqlite.Sqlite3.step(conn, ins)
      :ok = Exqlite.Sqlite3.reset(ins)
    end

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(conn, "SELECT json_extract(v, '$.a') FROM t ORDER BY rowid")

    :ok = Exqlite.Sqlite3.bind(stmt, [])
    {conn, stmt}
  end

  describe "fetch_all/2" do
    test "returns an error instead of silently truncating on a mid-scan failure" do
      {conn, stmt} = failing_statement()

      assert {:error, "malformed JSON"} = Barograph.Rows.fetch_all(conn, stmt)
    end

    test "returns all rows on a clean scan", context do
      path = Path.join(context.tmp_dir, "rows.bg")
      {:ok, conn} = Exqlite.Sqlite3.open(path)
      :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE t (v INTEGER)")
      {:ok, ins} = Exqlite.Sqlite3.prepare(conn, "INSERT INTO t VALUES (?1)")

      for v <- [1, 2, 3] do
        :ok = Exqlite.Sqlite3.bind(ins, [v])
        :done = Exqlite.Sqlite3.step(conn, ins)
        :ok = Exqlite.Sqlite3.reset(ins)
      end

      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT v FROM t ORDER BY v")
      :ok = Exqlite.Sqlite3.bind(stmt, [])

      assert {:ok, [[1], [2], [3]]} = Barograph.Rows.fetch_all(conn, stmt)
    end
  end

  describe "fetch_all!/2" do
    test "raises instead of silently truncating on a mid-scan failure" do
      {conn, stmt} = failing_statement()

      assert_raise RuntimeError, ~r/malformed JSON/, fn ->
        Barograph.Rows.fetch_all!(conn, stmt)
      end
    end
  end

  describe "Barograph.sql/3 (public API)" do
    test "surfaces a mid-scan failure as {:error, _} rather than partial rows", context do
      path = Path.join(context.tmp_dir, "sql.bg")
      {:ok, db} = Barograph.open(path)

      assert {:ok, _} = Barograph.sql(db, "CREATE TABLE probe (v TEXT)")

      for v <- [~s({"a":1}), ~s({"a":2}), "not valid json", ~s({"a":4})] do
        assert {:ok, _} = Barograph.sql(db, "INSERT INTO probe VALUES (?1)", [v])
      end

      assert {:error, _reason} =
               Barograph.sql(db, "SELECT json_extract(v, '$.a') FROM probe ORDER BY rowid")
    end
  end
end
