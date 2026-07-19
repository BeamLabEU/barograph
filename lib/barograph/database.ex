defmodule Barograph.Database do
  @moduledoc """
  Supervisor for one open database (spec §4.1).

  Children:

    * `Barograph.SeriesCache` — ETS label hash → series id cache
    * `Barograph.Writer` — owns the single write connection
    * `Barograph.Refresher` — periodic continuous-aggregate refresh

  Started with `:rest_for_one` so a crash of the series cache also
  restarts the writer, which re-warms the cache on boot.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    db = Keyword.fetch!(opts, :name)

    children = [
      {Barograph.SeriesCache, db: db},
      {Barograph.Writer, Keyword.put(opts, :db, db)},
      {Barograph.Refresher, db: db}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
