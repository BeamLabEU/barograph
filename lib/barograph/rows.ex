defmodule Barograph.Rows do
  @moduledoc """
  Drains a prepared statement into a list of rows.

  `Exqlite.Sqlite3.step/2` returns `:done | :busy | {:row, row} |
  {:error, reason}`. `:busy` and `{:error, reason}` can both surface
  *after* a statement has already yielded rows — a lock timeout or a
  disk I/O error mid-scan, not just on the first step. The naive
  `Stream.repeatedly(&step/2) |> Stream.take_while(&match?({:row, _}, &1))`
  idiom treats those identically to `:done`, silently returning
  whatever rows were collected so far as if the query had succeeded.
  `fetch_all/2` and `fetch_all!/2` distinguish a genuine end-of-results
  from a failure instead.
  """

  @doc "Returns `{:ok, rows}`, or `{:error, reason}` if a step fails before `:done`."
  @spec fetch_all(Exqlite.Sqlite3.db(), Exqlite.Sqlite3.statement()) ::
          {:ok, [Exqlite.Sqlite3.row()]} | {:error, term()}
  def fetch_all(conn, statement), do: step_all(conn, statement, [])

  @doc "Like `fetch_all/2`, but raises on `:busy` or `{:error, reason}`."
  @spec fetch_all!(Exqlite.Sqlite3.db(), Exqlite.Sqlite3.statement()) :: [Exqlite.Sqlite3.row()]
  def fetch_all!(conn, statement) do
    case fetch_all(conn, statement) do
      {:ok, rows} -> rows
      {:error, reason} -> raise "barograph: failed to read result rows: #{inspect(reason)}"
    end
  end

  defp step_all(conn, statement, acc) do
    case Exqlite.Sqlite3.step(conn, statement) do
      {:row, row} -> step_all(conn, statement, [row | acc])
      :done -> {:ok, Enum.reverse(acc)}
      :busy -> {:error, :busy}
      {:error, reason} -> {:error, reason}
    end
  end
end
