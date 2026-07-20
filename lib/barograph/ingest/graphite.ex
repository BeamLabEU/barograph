if Code.ensure_loaded?(ThousandIsland) do
  defmodule Barograph.Ingest.Graphite do
    @moduledoc """
    Graphite plaintext line protocol listener (spec §10.1).

    Only compiled when the optional `:thousand_island` dependency is
    present — see `Barograph.Ingest.Supervisor` for the runtime guard that
    applies when `:ingest` is configured but it's absent.
    """

    use ThousandIsland.Handler

    require Logger

    alias Barograph.Ingest.Graphite.Parser

    @impl ThousandIsland.Handler
    def handle_connection(_socket, state) do
      state =
        state
        |> Map.put(:buffer, "")
        |> Map.put(:time_unit, Barograph.time_unit(state.db))

      {:continue, state}
    end

    @impl ThousandIsland.Handler
    def handle_data(data, _socket, state) do
      buffer = state.buffer <> data

      if byte_size(buffer) > state.max_line_length and not String.contains?(buffer, "\n") do
        Logger.warning("barograph: graphite line exceeds max_line_length, closing connection")
        {:close, state}
      else
        {lines, rest} = split_lines(buffer)
        samples = Enum.flat_map(lines, &parse(&1, state))
        if samples != [], do: ingest(state.db, samples)
        {:continue, %{state | buffer: rest}}
      end
    end

    @doc "Bound port for a database's Graphite listener. Mainly useful for tests using `port: 0`."
    @spec port(Barograph.db()) :: {:ok, :inet.port_number()} | :error
    def port(db) do
      db
      |> then(&Barograph.Ingest.Supervisor.listener_name(:graphite, &1))
      |> ThousandIsland.listener_info()
      |> case do
        {:ok, {_ip, port}} -> {:ok, port}
        _ -> :error
      end
    end

    # TCP is a byte stream, not message-framed — partial lines are carried
    # forward in state.buffer across handle_data/3 calls.
    defp split_lines(buffer) do
      parts = String.split(buffer, "\n")
      {lines, [rest]} = Enum.split(parts, -1)
      {lines, rest}
    end

    defp parse(line, state) do
      case Parser.parse_line(line, state.template) do
        {:ok, {metric, labels, value, ts}} ->
          [{metric, labels, value, System.convert_time_unit(ts, :second, state.time_unit)}]

        :error ->
          if String.trim(line) != "" do
            Logger.warning("barograph: skipping malformed graphite line: #{inspect(line)}")
          end

          []
      end
    end

    # No application-level ack in this protocol to signal back-pressure
    # upstream, so drop + log is the only sane choice for a fire-and-forget
    # listener (spec §7.2's :overloaded).
    defp ingest(db, samples) do
      case Barograph.write_many(db, samples) do
        :ok ->
          :ok

        {:error, :overloaded} ->
          Logger.warning(
            "barograph: dropped #{length(samples)} graphite sample(s), writer overloaded"
          )
      end
    end
  end
end
