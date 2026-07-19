defmodule Barograph.SQL do
  @moduledoc """
  Raw SQL execution against a Barograph database.

  Level 3 of the query layer (spec §9.2): always available, never
  second-class. Each call opens a short-lived read connection — WAL
  mode allows concurrent readers alongside the single writer, so reads
  never contend with the write path. A dedicated read pool replaces
  this when the Ecto integration lands.
  """

  @doc """
  Runs `sql` with positional (`?1`, `?2`, …) parameters against the
  database behind `db`.

  Returns `{:ok, rows}` where each row is a map of column name to
  value, or `{:error, reason}`.
  """
  @spec query(Barograph.db(), String.t(), [term()]) ::
          {:ok, [%{String.t() => term()}]} | {:error, term()}
  def query(db, sql, params \\ []) do
    path = path(db)

    with {:ok, conn} <- Exqlite.Sqlite3.open(path) do
      try do
        with :ok <- Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout = 5000"),
             {:ok, statement} <- Exqlite.Sqlite3.prepare(conn, sql),
             :ok <- Exqlite.Sqlite3.bind(statement, params),
             {:ok, columns} <- Exqlite.Sqlite3.columns(conn, statement),
             {:ok, raw_rows} <- Barograph.Rows.fetch_all(conn, statement) do
          :ok = Exqlite.Sqlite3.release(conn, statement)
          {:ok, Enum.map(raw_rows, &Map.new(Enum.zip(columns, &1)))}
        end
      after
        # Close on every path, error included — statements are freed
        # with the connection.
        Exqlite.Sqlite3.close(conn)
      end
    end
  end

  defp path({:via, Registry, {Barograph.Registry, {:database, path}}}), do: path
end
