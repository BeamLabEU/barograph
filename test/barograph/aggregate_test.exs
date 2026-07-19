defmodule Barograph.AggregateTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp open(context) do
    path = Path.join(context.tmp_dir, "agg.bg")
    {:ok, db} = Barograph.open(path)
    db
  end

  # Hour-aligned base three hours ago; one sample per minute for two hours.
  defp seed(db, opts \\ []) do
    now = System.os_time(:second)
    base = div(now - 3 * 3_600, 3_600) * 3_600
    value_fun = Keyword.get(opts, :value_fun, fn minute -> 90.0 + minute / 10 end)

    samples =
      for minute <- 0..119 do
        {"cpu_usage", %{host: "web-1"}, value_fun.(minute), base + minute * 60}
      end

    :ok = Barograph.write_many(db, samples)
    :ok = Barograph.flush(db)
    base
  end

  defp agg_rows(db, name) do
    {:ok, rows} =
      Barograph.sql(db, "SELECT * FROM bg_agg_#{name} ORDER BY bucket")

    rows
  end

  describe "create_continuous_aggregate/3" do
    test "creates the rollup table and registers metadata", context do
      db = open(context)

      assert :ok =
               Barograph.create_continuous_aggregate(db, "cpu_1h",
                 from: "cpu_usage",
                 bucket: {1, :hour},
                 refresh_lag: {5, :minute},
                 refresh_every: {1, :minute}
               )

      assert {:ok, [%{"name" => "cpu_1h", "source" => "cpu_usage", "bucket_width" => 3_600, "lag" => 300, "refresh_every" => 60_000}]} =
               Barograph.sql(db, "SELECT name, source, bucket_width, lag, refresh_every FROM bg_agg_meta")

      assert {:ok, [_ | _]} =
               Barograph.sql(db, "SELECT name FROM pragma_table_info('bg_agg_cpu_1h')")
    end

    test "rejects invalid names, duplicates, and bad options", context do
      db = open(context)

      assert {:error, {:invalid_aggregate_name, _}} =
               Barograph.create_continuous_aggregate(db, "cpu_1h; DROP TABLE bg_meta",
                 from: "cpu_usage", bucket: {1, :hour}, refresh_lag: {5, :minute}, refresh_every: {1, :minute})

      assert {:error, {:missing_option, :from}} =
               Barograph.create_continuous_aggregate(db, "cpu_1h",
                 bucket: {1, :hour}, refresh_lag: {5, :minute}, refresh_every: {1, :minute})

      assert :ok =
               Barograph.create_continuous_aggregate(db, "cpu_1h",
                 from: "cpu_usage", bucket: {1, :hour}, refresh_lag: {5, :minute}, refresh_every: {1, :minute})

      assert {:error, {:aggregate_exists, "cpu_1h"}} =
               Barograph.create_continuous_aggregate(db, "cpu_1h",
                 from: "cpu_usage", bucket: {1, :hour}, refresh_lag: {5, :minute}, refresh_every: {1, :minute})
    end
  end

  describe "refresh" do
    test "computes partial aggregate state per bucket", context do
      db = open(context)
      base = seed(db)

      :ok =
        Barograph.create_continuous_aggregate(db, "cpu_1h",
          from: "cpu_usage", bucket: {1, :hour}, refresh_lag: {0, :second}, refresh_every: {1, :minute})

      assert :ok = Barograph.refresh_aggregates(db)

      assert [first, second] = agg_rows(db, "cpu_1h")

      assert %{
               "bucket" => ^base,
               "count" => 60,
               "min" => 90.0,
               "max" => 95.9,
               "first_ts" => ^base,
               "first_val" => 90.0,
               "last_ts" => last_ts,
               "last_val" => 95.9
             } = first

      assert last_ts == base + 59 * 60
      assert_in_delta first["sum"], Enum.sum(Enum.map(0..59, &(90.0 + &1 / 10))), 0.001
      assert first["sum_dt"] > 0
      assert first["sum_v_dt"] > 0

      assert %{"bucket" => bucket2, "count" => 60} = second
      assert bucket2 == base + 3_600
    end

    test "watermark advances; refresh is incremental and idempotent", context do
      db = open(context)
      base = seed(db)

      :ok =
        Barograph.create_continuous_aggregate(db, "cpu_1h",
          from: "cpu_usage", bucket: {1, :hour}, refresh_lag: {0, :second}, refresh_every: {1, :minute})

      assert :ok = Barograph.refresh_aggregates(db)
      assert {:ok, [%{"watermark" => watermark}]} =
               Barograph.sql(db, "SELECT watermark FROM bg_agg_meta WHERE name = 'cpu_1h'")
      assert watermark >= base + 3_600

      # Rerunning with no new data changes nothing.
      assert :ok = Barograph.refresh_aggregates(db)
      assert [%{"count" => 60}, %{"count" => 60}] =
               Enum.map(agg_rows(db, "cpu_1h"), &Map.take(&1, ["count"]))
    end

    test "respects refresh lag — recent buckets stay unfinalised", context do
      db = open(context)
      now = System.os_time(:second)
      base = div(now, 60) * 60

      :ok = Barograph.write_many(db, for(m <- 0..10, do: {"cpu_usage", %{}, 1.0, base - m * 60}))
      :ok = Barograph.flush(db)

      :ok =
        Barograph.create_continuous_aggregate(db, "cpu_1m",
          from: "cpu_usage", bucket: {1, :minute}, refresh_lag: {5, :minute}, refresh_every: {1, :minute})

      assert :ok = Barograph.refresh_aggregates(db)

      buckets = Enum.map(agg_rows(db, "cpu_1m"), & &1["bucket"])
      assert buckets != []

      # Only buckets that ended at or before now - lag are finalised.
      upper = div(System.os_time(:second) - 300, 60) * 60
      assert Enum.all?(buckets, &(&1 + 60 <= upper))
      refute base in buckets
    end

    test "late data below the watermark invalidates and recomputes its bucket", context do
      db = open(context)
      base = seed(db)

      :ok =
        Barograph.create_continuous_aggregate(db, "cpu_1h",
          from: "cpu_usage", bucket: {1, :hour}, refresh_lag: {0, :second}, refresh_every: {1, :minute})

      assert :ok = Barograph.refresh_aggregates(db)
      assert [%{"count" => 60} | _] = agg_rows(db, "cpu_1h")

      # Late sample landing in the first, already-finalised bucket.
      assert :ok = Barograph.write(db, "cpu_usage", %{host: "web-1"}, 500.0, base + 30 * 60 + 30)
      assert :ok = Barograph.flush(db)

      assert {:ok, [%{"bucket" => ^base}]} =
               Barograph.sql(db, "SELECT bucket FROM bg_agg_invalid WHERE name = 'cpu_1h'")

      assert :ok = Barograph.refresh_aggregates(db)

      assert {:ok, []} = Barograph.sql(db, "SELECT bucket FROM bg_agg_invalid WHERE name = 'cpu_1h'")
      assert [%{"count" => 61, "max" => 500.0} | _] = agg_rows(db, "cpu_1h")
    end
    test "a sample exactly at the refresh upper bound is not dropped", context do
      db = open(context)
      base = seed(db)
      path = Path.join(context.tmp_dir, "agg.bg")

      :ok =
        Barograph.create_continuous_aggregate(db, "cpu_1h",
          from: "cpu_usage", bucket: {1, :hour}, refresh_lag: {0, :second}, refresh_every: {1, :minute})

      # Drive refresh with a controlled `now` so its upper bound lands
      # exactly on the sample at base + 3600 (regression: that sample
      # used to vanish from the aggregate — review finding B1).
      {:ok, conn} = Exqlite.Sqlite3.open(path)
      :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout = 5000")
      [defn] = Barograph.Aggregate.definitions(conn)

      # First refresh finalises only the first bucket; the boundary
      # sample stays in its incomplete bucket.
      :ok = Barograph.Aggregate.refresh(conn, defn, base + 3_600)
      assert [%{"bucket" => ^base, "count" => 60}] = agg_rows(db, "cpu_1h")

      # Second refresh finalises the second bucket — including the
      # boundary sample at base + 3600.
      [defn] = Barograph.Aggregate.definitions(conn)
      :ok = Barograph.Aggregate.refresh(conn, defn, base + 7_200)

      assert [%{"count" => 60}, %{"bucket" => second, "count" => 60, "first_ts" => first_ts}] =
               agg_rows(db, "cpu_1h")

      assert second == base + 3_600
      assert first_ts == base + 3_600

      :ok = Exqlite.Sqlite3.close(conn)
    end
  end

  describe "refresher" do
    @tag :slow
    test "refreshes automatically on the refresh_every interval", context do
      db = open(context)
      seed(db)

      :ok =
        Barograph.create_continuous_aggregate(db, "cpu_1h",
          from: "cpu_usage", bucket: {1, :hour}, refresh_lag: {0, :second}, refresh_every: {1, :second})

      Process.sleep(1_500)
      assert [%{"count" => 60} | _] = agg_rows(db, "cpu_1h")
    end
  end
end
