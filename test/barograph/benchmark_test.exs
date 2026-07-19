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

  @tag timeout: 120_000
  test "query latency over a month of 1-minute data", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "bench_query.bg")
    {:ok, db} = Barograph.open(path)

    days = 30
    total = days * 24 * 60

    1..total
    |> Stream.chunk_every(1_000)
    |> Enum.each(fn chunk ->
      :ok =
        Barograph.write_many(
          db,
          Enum.map(chunk, fn i -> {"bench.metric", %{host: "bench-1"}, i * 1.0, (i - 1) * 60} end)
        )
    end)

    :ok = Barograph.flush(db)

    {micros, {:ok, rows}} =
      :timer.tc(fn ->
        Barograph.query(db, "bench.metric",
          labels: %{host: "bench-1"},
          bucket: {1, :hour},
          agg: :avg
        )
      end)

    IO.puts(
      "\n#{total} samples bucketed hourly in #{div(micros, 1_000)} ms (#{length(rows)} buckets)"
    )

    assert length(rows) == days * 24
    assert micros < 100_000
  end
end
