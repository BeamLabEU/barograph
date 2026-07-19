defmodule Barograph.QueryTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # One sample per minute for 3 hours across two forklifts.
  defp seed(context) do
    path = Path.join(context.tmp_dir, "query.bg")
    {:ok, db} = Barograph.open(path)

    base = 1_752_930_000

    samples =
      for minute <- 0..179 do
        ts = base + minute * 60
        fl = if rem(minute, 2) == 0, do: "FL-07", else: "FL-11"
        {"engine_temp", %{forklift: fl}, 90.0 + minute / 10, ts}
      end

    :ok = Barograph.write_many(db, samples)
    :ok = Barograph.flush(db)

    %{db: db, path: path, base: base}
  end

  describe "query/3 with bucket and agg" do
    test "buckets hourly averages", context do
      %{db: db, base: base} = seed(context)

      assert {:ok, rows} =
               Barograph.query(db, "engine_temp", bucket: {1, :hour}, agg: :avg)

      assert length(rows) == 3
      assert Enum.map(rows, & &1.bucket) == [base, base + 3_600, base + 7_200]
      assert Enum.all?(rows, &is_float(&1.value))
    end

    test "supports min, max, sum, and count", context do
      %{db: db} = seed(context)

      for agg <- [:min, :max, :sum, :count] do
        assert {:ok, rows} = Barograph.query(db, "engine_temp", bucket: {1, :hour}, agg: agg)
        assert length(rows) == 3
      end

      assert {:ok, [%{value: 60} | _]} =
               Barograph.query(db, "engine_temp", bucket: {1, :hour}, agg: :count)
    end

    test "filters by labels", context do
      %{db: db} = seed(context)

      assert {:ok, rows} =
               Barograph.query(db, "engine_temp",
                 labels: %{forklift: "FL-07"},
                 bucket: {1, :hour},
                 agg: :count
               )

      # Even minutes only: 30 per hour.
      assert Enum.map(rows, & &1.value) == [30, 30, 30]
    end

    test "filters by time range, to exclusive", context do
      %{db: db, base: base} = seed(context)

      from = DateTime.from_unix!(base)
      to = DateTime.from_unix!(base + 3_600)

      assert {:ok, rows} =
               Barograph.query(db, "engine_temp",
                 from: from,
                 to: to,
                 agg: :count,
                 bucket: {1, :hour}
               )

      assert [%{value: 60}] = rows
    end

    test "accepts integer epochs for from and to", context do
      %{db: db, base: base} = seed(context)

      assert {:ok, rows} =
               Barograph.query(db, "engine_temp",
                 from: base + 7_200,
                 agg: :count,
                 bucket: {1, :hour}
               )

      assert [%{value: 60}] = rows
    end

    test "rejects an invalid aggregate and bucket", context do
      %{db: db} = seed(context)

      assert {:error, {:invalid_aggregate, :median}} =
               Barograph.query(db, "engine_temp", bucket: {1, :hour}, agg: :median)

      assert {:error, {:invalid_bucket, _}} =
               Barograph.query(db, "engine_temp", bucket: {1, :fortnight})
    end
  end

  describe "query/3 without bucket" do
    test "returns raw samples ordered by time", context do
      %{db: db} = seed(context)

      assert {:ok, rows} = Barograph.query(db, "engine_temp", labels: %{forklift: "FL-07"})
      assert length(rows) == 90
      assert [%{ts: _, value: _} | _] = rows
      assert rows == Enum.sort_by(rows, & &1.ts)
    end
  end

  describe "sql/3" do
    test "runs raw SQL with parameters and returns maps", context do
      %{db: db} = seed(context)

      assert {:ok, rows} =
               Barograph.sql(db, "SELECT metric, labels FROM bg_series WHERE metric = ?1", [
                 "engine_temp"
               ])

      labels = rows |> Enum.map(& &1["labels"]) |> Enum.sort() |> Enum.map(&JSON.decode!/1)
      assert [%{"forklift" => "FL-07"}, %{"forklift" => "FL-11"}] = labels
      assert Enum.all?(rows, &(&1["metric"] == "engine_temp"))
    end

    test "joins samples and series by hand, no library involved", context do
      %{db: db} = seed(context)

      assert {:ok, [%{"n" => 180}]} =
               Barograph.sql(db, """
               SELECT count(*) AS n
               FROM bg_samples s JOIN bg_series r ON r.id = s.series_id
               WHERE r.metric = 'engine_temp'
               """)
    end

    test "returns errors instead of raising", context do
      %{db: db} = seed(context)

      assert {:error, _reason} = Barograph.sql(db, "SELECT * FROM nope")
    end
  end

  describe "time_unit/1" do
    test "reports the unit fixed at creation", context do
      path = Path.join(context.tmp_dir, "unit.bg")
      {:ok, db} = Barograph.open(path, time_unit: :microsecond)
      assert Barograph.time_unit(db) == :microsecond
    end
  end
end
