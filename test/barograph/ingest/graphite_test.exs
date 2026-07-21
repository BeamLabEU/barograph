defmodule Barograph.Ingest.GraphiteTest do
  use ExUnit.Case, async: true

  alias Barograph.Ingest.Graphite

  @moduletag :tmp_dir

  defp db_path(%{tmp_dir: tmp_dir}), do: Path.join(tmp_dir, "test.bg")

  defp open_with_listener(context, ingest_opts \\ []) do
    path = db_path(context)
    graphite_opts = Keyword.merge([port: 0], ingest_opts)
    {:ok, db} = Barograph.open(path, ingest: [graphite: graphite_opts])
    {:ok, port} = Graphite.port(db)
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
    {db, socket}
  end

  # A TCP send only enqueues bytes on the OS socket buffer — the remote
  # handler process ingests them asynchronously. Poll (bounded) rather than
  # sleep a fixed amount: fast on the common case, still deterministic on a
  # slow CI box, and fails loudly (not silently short-circuits) on timeout.
  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: flunk("condition not met within the polling window")

  defp eventually(fun, attempts) do
    case fun.() do
      false ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  defp query_until(db, metric, opts, match_fun) do
    eventually(fn -> poll_query(db, metric, opts, match_fun) end)
  end

  defp poll_query(db, metric, opts, match_fun) do
    :ok = Barograph.flush(db)

    with {:ok, points} <- Barograph.query(db, metric, opts),
         true <- match_fun.(points) do
      {:ok, points}
    else
      _ -> false
    end
  end

  defp query_until(db, metric), do: query_until(db, metric, [], &(&1 != []))

  test "a single line lands in the database end-to-end", context do
    {db, socket} = open_with_listener(context)

    :ok = :gen_tcp.send(socket, "engine_temp 94.2 1752931200\n")

    assert {:ok, [%{ts: 1_752_931_200, value: 94.2}]} = query_until(db, "engine_temp")
  end

  test "a line split across two TCP sends is still parsed correctly", context do
    {db, socket} = open_with_listener(context)

    :ok = :gen_tcp.send(socket, "engine_temp 94.")
    :ok = :gen_tcp.send(socket, "2 1752931200\n")

    assert {:ok, [%{value: 94.2}]} = query_until(db, "engine_temp")
  end

  test "multiple lines in one packet all land", context do
    {db, socket} = open_with_listener(context)

    :ok = :gen_tcp.send(socket, "m 1.0 100\nm 2.0 200\nm 3.0 300\n")

    assert {:ok, points} = query_until(db, "m", [], &(length(&1) == 3))
    assert Enum.map(points, & &1.value) |> Enum.sort() == [1.0, 2.0, 3.0]
  end

  test "a malformed line does not close the connection or block later valid lines", context do
    {db, socket} = open_with_listener(context)

    :ok = :gen_tcp.send(socket, "this is not a valid line\n")
    :ok = :gen_tcp.send(socket, "m 1.0 100\n")

    assert {:ok, [%{value: 1.0}]} = query_until(db, "m")
  end

  test "graphite 1.1+ tag syntax lands with labels", context do
    {db, socket} = open_with_listener(context)

    :ok = :gen_tcp.send(socket, "engine_temp;forklift=FL-07 94.2 1752931200\n")

    assert {:ok, [%{value: 94.2}]} =
             query_until(db, "engine_temp", [labels: %{"forklift" => "FL-07"}], &(&1 != []))
  end

  test "two concurrent connections to the same listener both ingest", context do
    {db, socket_a} = open_with_listener(context)
    {:ok, port} = Graphite.port(db)
    {:ok, socket_b} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])

    :ok = :gen_tcp.send(socket_a, "a 1.0 100\n")
    :ok = :gen_tcp.send(socket_b, "b 2.0 200\n")

    assert {:ok, [%{value: 1.0}]} = query_until(db, "a")
    assert {:ok, [%{value: 2.0}]} = query_until(db, "b")
  end

  test "a configured template splits metric and labels end-to-end", context do
    {db, socket} = open_with_listener(context, template: "*.forklift.metric")

    :ok = :gen_tcp.send(socket, "forklift.FL-07.engine.temp 94.2 1752931200\n")

    assert {:ok, [%{value: 94.2}]} =
             query_until(db, "engine.temp", [labels: %{"forklift" => "FL-07"}], &(&1 != []))
  end

  test "graphite's unix-second timestamps convert to the database's time unit", context do
    path = db_path(context)
    {:ok, db} = Barograph.open(path, time_unit: :millisecond, ingest: [graphite: [port: 0]])
    {:ok, port} = Graphite.port(db)
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])

    :ok = :gen_tcp.send(socket, "m 1.0 1752931200\n")

    assert {:ok, [%{ts: 1_752_931_200_000}]} = query_until(db, "m")
  end

  test "a complete line longer than max_line_length closes the connection", context do
    {_db, socket} = open_with_listener(context, max_line_length: 16)

    :ok = :gen_tcp.send(socket, String.duplicate("x", 100) <> " 1.0 100\n")

    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2000)
  end

  test "an oversized remainder without a trailing newline still closes the connection", context do
    # Regression for the bug where the old pre-split check only fired when
    # the buffer had *no* newline at all — a short valid line followed by
    # an unbounded, newline-less remainder in the same read bypassed it.
    {_db, socket} = open_with_listener(context, max_line_length: 16)

    :ok = :gen_tcp.send(socket, "ok\n" <> String.duplicate("x", 100))

    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2000)
  end

  test "an invalid-UTF-8 tag value is skipped without crashing the writer or the connection",
       context do
    {db, socket} = open_with_listener(context)

    bad = <<"m;tag=", 0xFF, 0xFE, " 1.0 100\n">>
    :ok = :gen_tcp.send(socket, bad)
    :ok = :gen_tcp.send(socket, "m 2.0 200\n")

    assert {:ok, [%{value: 2.0}]} = query_until(db, "m")
  end
end
