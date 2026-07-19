defmodule Barograph.SeriesCache do
  @moduledoc """
  ETS cache mapping `{metric, labels_hash}` to `series_id` (spec §7.4).

  The write path must never join to resolve a series. The table is
  `:public` with `read_concurrency: true` so the writer and future read
  pool can look up series without serialising through this process; the
  GenServer exists only to own the table and register its tid.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Returns the ETS tid for a database's series cache."
  @spec table(Barograph.db()) :: :ets.tid() | nil
  def table(db) do
    case Registry.lookup(Barograph.Registry, registry_key(db)) do
      [{_pid, tid}] -> tid
      [] -> nil
    end
  end

  @doc "Looks up the series id for a metric and 16-byte labels hash."
  @spec lookup(:ets.tid(), String.t(), binary()) :: {:ok, integer()} | :miss
  def lookup(tid, metric, labels_hash) do
    case :ets.lookup(tid, {metric, labels_hash}) do
      [{{^metric, ^labels_hash}, series_id}] -> {:ok, series_id}
      [] -> :miss
    end
  end

  @doc "Caches a series id under its metric and labels hash."
  @spec put(:ets.tid(), String.t(), binary(), integer()) :: true
  def put(tid, metric, labels_hash, series_id) do
    :ets.insert(tid, {{metric, labels_hash}, series_id})
  end

  @impl true
  def init(opts) do
    db = Keyword.fetch!(opts, :db)

    tid =
      :ets.new(:series_cache, [
        :set,
        :public,
        read_concurrency: true,
        decentralized_counters: true
      ])

    {:ok, _pid} = Registry.register(Barograph.Registry, registry_key(db), tid)
    {:ok, %{tid: tid}}
  end

  defp registry_key({:via, Registry, {Barograph.Registry, {:database, key}}}),
    do: {:series_cache, key}
end
