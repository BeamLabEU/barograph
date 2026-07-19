defmodule Barograph do
  @moduledoc """
  Time-series and event analytics for Elixir, stored in SQLite.

  One file. No server. Full SQL.
  """

  @typedoc """
  A handle to an open Barograph database.

  A `:via` tuple registered in `Barograph.Registry`, usable anywhere a
  GenServer name is accepted.
  """
  @type db :: {:via, Registry, {Barograph.Registry, {:database, String.t()}}}

  @doc """
  Opens (or creates) a Barograph database at `path`.

  If the file does not exist, it is created and initialised with the
  Barograph schema. If it exists and was written by Barograph, its
  metadata is checked and the database is opened. Anything else is
  rejected.

  ## Options

    * `:time_unit` - `:second` (default), `:millisecond`, or `:microsecond`.
      Fixed at creation; must match when reopening an existing database.

  ## Examples

      {:ok, db} = Barograph.open("/var/data/metrics.bg")

  """
  @spec open(Path.t(), keyword()) :: {:ok, db()} | {:error, term()}
  def open(path, opts \\ []) when is_binary(path) do
    key = Path.expand(path)
    name = {:via, Registry, {Barograph.Registry, {:database, key}}}

    child_opts =
      opts
      |> Keyword.put(:path, key)
      |> Keyword.put(:name, name)

    case DynamicSupervisor.start_child(
           Barograph.DatabaseSupervisor,
           {Barograph.Database, child_opts}
         ) do
      {:ok, _pid} -> {:ok, name}
      {:error, {:already_started, _pid}} -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Closes an open database, terminating its writer and read pool.

  The file itself is untouched.
  """
  @spec close(db()) :: :ok
  def close(db) do
    case GenServer.whereis(db) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Barograph.DatabaseSupervisor, pid)
    end
  end
end
