defmodule Barograph.BenchmarkTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag :benchmark

  @samples 200_000
  @chunk 1_000

  test "sustained write throughput", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "bench.bg")
    {:ok, db} = Barograph.open(path)

    batches =
      Stream.chunk_every(1..@samples, @chunk)
      |> Enum.map(fn chunk ->
        Enum.map(chunk, fn i -> {"bench.metric", %{host: "bench-1"}, i * 1.0, i} end)
      end)

    {micros, :ok} =
      :timer.tc(fn ->
        Enum.each(batches, fn batch ->
          :ok = Barograph.write_many(db, batch)
        end)

        Barograph.flush(db)
      end)

    rate = div(@samples * 1_000_000, max(micros, 1))

    IO.puts(
      "\n#{@samples} samples in #{div(micros, 1_000)} ms " <>
        "(#{rate} samples/sec, db #{div(File.stat!(path).size, 1024)} KiB)"
    )

    assert rate > 10_000
  end
end
