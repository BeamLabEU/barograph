defmodule Barograph.Barogram do
  @moduledoc """
  Renders query results as SVG — a *barogram* is the trace a barograph
  produces (spec §11).

  SVG, not PNG: no image encoder, no NIF, no headless browser; text
  output that diffs efficiently over a LiveView websocket and is
  CSS-themeable by the host application. Elements carry `barogram-*`
  classes; the line itself strokes `currentColor`.

  v0.1 scope is the line chart. Area, step, scatter, and legends are
  v0.5 (spec §11.3).
  """

  @default_width 800
  @default_height 200
  @pad_left 56
  @pad_right 16
  @pad_top 16
  @pad_bottom 28
  @grid_lines 4
  @max_hover_points 500

  @typedoc "A point map as returned by `Barograph.query/3` (`%{bucket, value}` or `%{ts, value}`)."
  @type point :: %{optional(:bucket) => number(), optional(:ts) => number(), value: number()}

  @doc """
  Renders a list of query-result points as an SVG line chart string.

  Points are maps with a `:value` and either a `:bucket` or `:ts` key —
  exactly what `Barograph.query/3` returns, so results pipe straight in.

  ## Options

    * `:width` - viewBox width (default #{@default_width})
    * `:height` - viewBox height (default #{@default_height})
    * `:style` - only `:line` for now (area/step/scatter are v0.5)

  Points beyond #{@max_hover_points} are rendered without per-point
  hover titles to keep the document small.
  """
  @spec svg([point()], keyword()) :: String.t()
  def svg(points, opts \\ []) when is_list(points) do
    width = Keyword.get(opts, :width, @default_width)
    height = Keyword.get(opts, :height, @default_height)

    case Keyword.get(opts, :style, :line) do
      :line ->
        render(normalize(points), width, height)

      other ->
        raise ArgumentError,
              "unsupported barogram style: #{inspect(other)} (only :line is supported in v0.1)"
    end
  end

  ## Data

  defp normalize(points) do
    points
    |> Enum.map(fn
      %{bucket: x, value: y} -> {x * 1.0, y * 1.0}
      %{ts: x, value: y} -> {x * 1.0, y * 1.0}
    end)
    |> Enum.sort_by(fn {x, _y} -> x end)
  end

  ## Rendering

  defp render([], width, height) do
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{width} #{height}" width="#{width}" height="#{height}" role="img" class="barogram">
      <text class="barogram-empty" x="#{width / 2}" y="#{height / 2}" text-anchor="middle">no data</text>
    </svg>
    """
  end

  defp render(points, width, height) do
    {x_min, x_max} = points |> Enum.map(&elem(&1, 0)) |> Enum.min_max()
    {y_min, y_max} = points |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
    {y_min, y_max} = pad_y_range(y_min, y_max)

    plot_w = width - @pad_left - @pad_right
    plot_h = height - @pad_top - @pad_bottom

    scale_x = scaler(x_min, x_max, @pad_left, @pad_left + plot_w)
    scale_y = scaler(y_min, y_max, @pad_top + plot_h, @pad_top)

    polyline =
      points
      |> Enum.map(fn {x, y} -> "#{fmt_coord(scale_x.(x))},#{fmt_coord(scale_y.(y))}" end)
      |> Enum.join(" ")

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{width} #{height}" width="#{width}" height="#{height}" role="img" class="barogram">
    #{gridlines(y_min, y_max, width, scale_y)}
    #{x_labels(x_min, x_max, height, scale_x)}
      <line class="barogram-axis" x1="#{@pad_left}" y1="#{@pad_top}" x2="#{@pad_left}" y2="#{@pad_top + plot_h}"/>
      <line class="barogram-axis" x1="#{@pad_left}" y1="#{@pad_top + plot_h}" x2="#{@pad_left + plot_w}" y2="#{@pad_top + plot_h}"/>
      <polyline class="barogram-line" fill="none" stroke="currentColor" points="#{polyline}"/>
    #{hover_points(points, scale_x, scale_y)}
    </svg>
    """
  end

  defp gridlines(y_min, y_max, width, scale_y) do
    for i <- 0..@grid_lines do
      value = y_min + (y_max - y_min) * i / @grid_lines
      y = fmt_coord(scale_y.(value))

      """
        <line class="barogram-grid" x1="#{@pad_left}" y1="#{y}" x2="#{width - @pad_right}" y2="#{y}"/>
        <text class="barogram-ylabel" x="#{@pad_left - 6}" y="#{y}" text-anchor="end" dominant-baseline="middle">#{fmt_number(value)}</text>
      """
    end
    |> Enum.join()
  end

  defp x_labels(x_min, x_max, height, scale_x) do
    y = height - @pad_bottom + 18

    """
      <text class="barogram-xlabel" x="#{fmt_coord(scale_x.(x_min))}" y="#{y}" text-anchor="middle">#{fmt_number(x_min)}</text>
      <text class="barogram-xlabel" x="#{fmt_coord(scale_x.(x_max))}" y="#{y}" text-anchor="middle">#{fmt_number(x_max)}</text>
    """
  end

  defp hover_points(points, scale_x, scale_y) when length(points) <= @max_hover_points do
    points
    |> Enum.map(fn {x, y} ->
      """
        <circle class="barogram-point" cx="#{fmt_coord(scale_x.(x))}" cy="#{fmt_coord(scale_y.(y))}" r="2"><title>#{fmt_number(x)}, #{fmt_number(y)}</title></circle>
      """
    end)
    |> Enum.join()
  end

  defp hover_points(_points, _scale_x, _scale_y), do: ""

  ## Scaling and formatting

  defp scaler(d_min, d_max, r_min, r_max) when d_min == d_max do
    mid = (r_min + r_max) / 2
    fn _ -> mid end
  end

  defp scaler(d_min, d_max, r_min, r_max) do
    fn value -> r_min + (value - d_min) / (d_max - d_min) * (r_max - r_min) end
  end

  # 5% headroom so the trace doesn't touch the plot edges; degenerate
  # ranges (constant series) get a symmetric ±1 span.
  defp pad_y_range(y_min, y_max) when y_min == y_max, do: {y_min - 1, y_max + 1}

  defp pad_y_range(y_min, y_max) do
    pad = (y_max - y_min) * 0.05
    {y_min - pad, y_max + pad}
  end

  defp fmt_coord(number), do: :erlang.float_to_binary(number, decimals: 1)

  defp fmt_number(number) when is_float(number) do
    if number == Float.floor(number) do
      Integer.to_string(trunc(number))
    else
      number
      |> :erlang.float_to_binary(decimals: 2)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")
    end
  end

  defp fmt_number(number) when is_integer(number), do: Integer.to_string(number)
end
