defmodule Barograph.BarogramTest do
  use ExUnit.Case, async: true

  alias Barograph.Barogram

  @moduletag :tmp_dir

  defp sample_points do
    for i <- 0..9, do: %{bucket: i * 60, value: i * 10.0}
  end

  describe "svg/2" do
    test "produces a standalone SVG document with the requested size" do
      svg = Barogram.svg(sample_points(), width: 800, height: 200)

      assert svg =~ ~r|^<svg xmlns="http://www.w3.org/2000/svg"|
      assert svg =~ ~s|viewBox="0 0 800 200"|
      assert svg =~ ~s|width="800"|
      assert svg =~ ~s|height="200"|
      assert String.ends_with?(String.trim(svg), "</svg>")
    end

    test "renders the trace as a polyline stroked with currentColor" do
      svg = Barogram.svg(sample_points())

      assert svg =~
               ~r|<polyline class="barogram-line" fill="none" stroke="currentColor" points="[^"]+"/>|
    end

    test "scales endpoints to the padded plot area" do
      # Two points: x 0→100, y 0→100. y range padded by 5% → -5..105.
      svg =
        Barogram.svg([%{bucket: 0, value: 0.0}, %{bucket: 100, value: 100.0}],
          width: 200,
          height: 100
        )

      # Plot area: x in 56..184, y in 16..72 (inverted).
      # Point (0, 0):   x = 56,  y = 16 + 56 * (105/110) ≈ 69.5
      # Point (100, 100): x = 184, y = 16 + 56 * (5/110)  ≈ 18.5
      assert svg =~ ~s|points="56.0,69.5 184.0,18.5"|
    end

    test "renders gridlines with formatted y labels" do
      svg = Barogram.svg(sample_points())

      grid_count = svg |> String.split(~s|class="barogram-grid"|) |> length() |> Kernel.-(1)
      label_count = svg |> String.split(~s|class="barogram-ylabel"|) |> length() |> Kernel.-(1)

      assert grid_count == 5
      assert label_count == 5
    end

    test "renders first and last x labels" do
      svg = Barogram.svg(sample_points())
      assert svg =~ ~r|<text class="barogram-xlabel" x="56.0"[^>]*>0</text>|
      assert svg =~ ~r|<text class="barogram-xlabel" x="[^"]+"[^>]*>540</text>|
    end

    test "accepts %{ts, value} maps (unbucketed query results)" do
      svg = Barogram.svg([%{ts: 1, value: 1.0}, %{ts: 2, value: 2.0}])
      assert svg =~ ~s|<polyline|
    end

    test "sorts out-of-order points" do
      points = [%{bucket: 60, value: 2.0}, %{bucket: 0, value: 1.0}]
      svg = Barogram.svg(points)
      [_, coords] = Regex.run(~r|points="([^"]+)"|, svg)
      assert String.starts_with?(coords, "56.0,")
    end

    test "includes hover titles for small point counts" do
      svg = Barogram.svg(sample_points())
      assert svg =~ ~s|<title>0, 0</title>|
      assert svg =~ ~s|<title>540, 90</title>|
    end

    test "omits hover titles beyond 500 points" do
      points = for i <- 1..501, do: %{bucket: i, value: i * 1.0}
      refute Barogram.svg(points) =~ ~s|<circle|
    end

    test "handles a constant series without division by zero" do
      svg = Barogram.svg(for(i <- 1..5, do: %{bucket: i, value: 42.0}))
      assert svg =~ ~s|<polyline|
      assert svg =~ ~s|>42</text>|
    end

    test "handles a single point" do
      svg = Barogram.svg([%{bucket: 1, value: 1.0}])
      assert svg =~ ~s|<polyline|
    end

    test "handles empty data" do
      svg = Barogram.svg([])
      assert svg =~ ~s|<svg|
      assert svg =~ ~s|no data|
      refute svg =~ ~s|<polyline|
    end

    test "rejects unsupported styles" do
      assert_raise ArgumentError, ~r/unsupported barogram style/, fn ->
        Barogram.svg(sample_points(), style: :area)
      end
    end
  end

  describe "integration" do
    test "renders a Barograph.query/3 result directly", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "barogram.bg")
      {:ok, db} = Barograph.open(path)

      base = div(System.os_time(:second) - 3_600, 3_600) * 3_600
      samples = for m <- 0..59, do: {"engine_temp", %{}, 90.0 + m / 10, base + m * 60}
      :ok = Barograph.write_many(db, samples)
      :ok = Barograph.flush(db)

      assert {:ok, result} = Barograph.query(db, "engine_temp", bucket: {5, :minute}, agg: :avg)

      svg = Barogram.svg(result, width: 800, height: 200)
      assert svg =~ ~s|<polyline class="barogram-line"|
      assert svg =~ ~s|<title>#{base}, 90.2</title>|
    end
  end
end
