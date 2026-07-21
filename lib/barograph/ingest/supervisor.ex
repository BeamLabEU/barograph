defmodule Barograph.Ingest.Supervisor do
  @moduledoc """
  Supervises configured ingest listeners for one open database (spec §10).

  Started as an opt-in child of `Barograph.Database` via the `:ingest`
  option to `Barograph.open/2` — a documented deviation from spec §4.1's
  top-level diagram (see the v0.2 progress report): every other option in
  this library flows through `open/2`, and tying a listener's lifecycle to
  one already-open database means `Barograph.close/1` tears it down along
  with everything else.

  ## `:graphite` options

  `ingest: [graphite: [...]]`:

    * `:port` - TCP port to listen on. Defaults to `2003` (carbon's
      conventional plaintext port).
    * `:template` - dotted template string for splitting a path into
      metric + labels; `nil` (default) uses the whole path as the
      metric with no labels. See `Barograph.Ingest.Graphite.Parser.compile_template/1`.
    * `:max_line_length` - bytes; connections sending a longer line are
      closed. Defaults to `8192`.
    * `:transport_options` - passed through to `ThousandIsland`'s TCP
      transport, e.g. `ip: :loopback` to bind only the loopback
      interface instead of the default `0.0.0.0`. Defaults to `[]`
      (all interfaces).

  The Graphite plaintext protocol has no authentication and no
  transport security — anyone who can reach the port can write
  arbitrary samples, and each previously-unseen `{metric, labels}` pair
  creates a new series with no cardinality limit (same as the native
  `write/4,5` API, just reachable over the network without going
  through application code). For anything beyond local development,
  bind `transport_options: [ip: :loopback]` and put a real interface
  behind a firewall or private network, or front it with a proxy that
  adds authentication.
  """

  use Supervisor

  alias Barograph.Ingest.Graphite

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    db = Keyword.fetch!(opts, :db)

    if Code.ensure_loaded?(ThousandIsland) do
      Supervisor.start_link(__MODULE__, opts, name: supervisor_name(db))
    else
      {:error, {:missing_dependency, :thousand_island}}
    end
  end

  @impl true
  def init(opts) do
    db = Keyword.fetch!(opts, :db)

    children =
      opts
      |> Keyword.delete(:db)
      |> Enum.map(fn {protocol, protocol_opts} -> listener_spec(protocol, protocol_opts, db) end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Registry name for a protocol's listener under a database, for `ThousandIsland.listener_info/1`."
  @spec listener_name(atom(), Barograph.db()) :: GenServer.name()
  def listener_name(protocol, {:via, Registry, {Barograph.Registry, {:database, key}}}),
    do: {:via, Registry, {Barograph.Registry, {{:ingest, protocol}, key}}}

  defp listener_spec(:graphite, protocol_opts, db) do
    case Graphite.Parser.compile_template(protocol_opts[:template]) do
      {:ok, template} ->
        {ThousandIsland,
         port: Keyword.get(protocol_opts, :port, 2003),
         transport_options: Keyword.get(protocol_opts, :transport_options, []),
         handler_module: Graphite,
         handler_options: %{
           db: db,
           template: template,
           max_line_length: Keyword.get(protocol_opts, :max_line_length, 8192)
         },
         supervisor_options: [name: listener_name(:graphite, db)]}

      {:error, reason} ->
        raise ArgumentError, "barograph: invalid graphite ingest template: #{inspect(reason)}"
    end
  end

  defp listener_spec(protocol, _protocol_opts, _db),
    do: raise(ArgumentError, "barograph: unknown ingest protocol #{inspect(protocol)}")

  defp supervisor_name({:via, Registry, {Barograph.Registry, {:database, key}}}),
    do: {:via, Registry, {Barograph.Registry, {:ingest_supervisor, key}}}
end
