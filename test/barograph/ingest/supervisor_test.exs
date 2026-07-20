defmodule Barograph.Ingest.SupervisorTest do
  use ExUnit.Case, async: true

  alias Barograph.Ingest.Graphite

  @moduletag :tmp_dir

  defp db_path(%{tmp_dir: tmp_dir}), do: Path.join(tmp_dir, "test.bg")

  test "no :ingest option behaves exactly like a plain database", context do
    path = db_path(context)
    assert {:ok, db} = Barograph.open(path)
    assert :ok = Barograph.write(db, "m", %{}, 1.0)
    assert :ok = Barograph.flush(db)
    assert {:ok, [%{value: 1.0}]} = Barograph.query(db, "m")
  end

  test "an unknown ingest protocol fails open/2 without crashing the test process", context do
    path = db_path(context)
    assert {:error, _reason} = Barograph.open(path, ingest: [carbon_pigeon: [port: 0]])
  end

  test "an invalid graphite template fails open/2 without crashing the test process", context do
    path = db_path(context)

    assert {:error, _reason} =
             Barograph.open(path, ingest: [graphite: [port: 0, template: "no.metric.token"]])
  end

  test "close/1 tears down the ingest listener along with the rest of the database", context do
    path = db_path(context)
    assert {:ok, db} = Barograph.open(path, ingest: [graphite: [port: 0]])
    assert {:ok, port} = Graphite.port(db)

    assert {:ok, _socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])

    assert :ok = Barograph.close(db)

    assert {:error, :econnrefused} =
             :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
  end
end
