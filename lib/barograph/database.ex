defmodule Barograph.Database do
  @moduledoc """
  Supervisor for one open database (spec §4.1).

  Children:

    * `Barograph.SeriesCache` — ETS label hash → series id cache
    * `Barograph.Writer` — owns the single write connection
    * `Barograph.Refresher` — periodic continuous-aggregate refresh
    * `Barograph.Ingest.Supervisor` — opt-in, only present when `:ingest`
      is given to `Barograph.open/2` (spec §10)

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

    children =
      [
        {Barograph.SeriesCache, db: db},
        {Barograph.Writer, Keyword.put(opts, :db, db)},
        {Barograph.Refresher, db: db}
      ] ++ ingest_children(opts, db)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # Opt-in, last in the :rest_for_one chain: ingest depends on the writer
  # being alive, and a writer crash should also bounce any open listeners
  # rather than leave them accepting connections into a half-restarted db.
  defp ingest_children(opts, db) do
    case Keyword.get(opts, :ingest) do
      nil -> []
      ingest_opts -> [{Barograph.Ingest.Supervisor, Keyword.put(ingest_opts, :db, db)}]
    end
  end
end
