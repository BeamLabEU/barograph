defmodule Barograph.Refresher do
  @moduledoc """
  Periodic continuous-aggregate refresh (spec §8.6).

  The internal `:timer`-driven fallback: ticks at the smallest
  `refresh_every` across registered aggregates and runs a
  watermark-bounded refresh of all of them. Refresh is idempotent and
  proportional to new data, so ticking more often than strictly needed
  is harmless. When Oban is available it replaces this process —
  without changing what a refresh does.
  """

  use GenServer

  @idle_tick_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    db = Keyword.fetch!(opts, :db)
    {:ok, %{db: db}, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state), do: {:noreply, tick(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, tick(state)}

  defp tick(state) do
    writer = writer(state.db)
    definitions = Barograph.Writer.aggregate_definitions(writer)

    if definitions != [] do
      :ok = Barograph.Writer.refresh_aggregates(writer)
    end

    interval =
      case definitions do
        [] -> @idle_tick_ms
        defs -> defs |> Enum.map(& &1.refresh_every) |> Enum.min() |> max(100)
      end

    Process.send_after(self(), :tick, interval)
    state
  end

  defp writer({:via, Registry, {Barograph.Registry, {:database, key}}}),
    do: {:via, Registry, {Barograph.Registry, {:writer, key}}}
end
