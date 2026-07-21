defmodule Barograph.Ingest.Graphite.Parser do
  @moduledoc """
  Pure parsing for the Graphite plaintext line protocol (spec §10.1).

  No dependency on `thousand_island` — compiles and is testable
  regardless of whether that optional dependency is present.
  """

  @type template :: [String.t()]

  @doc """
  Compiles a dot-separated template string into matchable tokens.

  `"*"` skips a path segment. Any other token is a literal label key,
  matched against the segment at that position. The token `"metric"`
  must appear exactly once, only as the final token — it then greedily
  consumes all remaining path segments, joined with `.`.

      compile_template("*.forklift.metric") #=> {:ok, ["*", "forklift", "metric"]}

  `nil` compiles to `nil`: the whole dotted path is used verbatim as
  the metric name, with no labels — zero config for plain ingest.
  """
  @spec compile_template(String.t() | nil) :: {:ok, template() | nil} | {:error, atom()}
  def compile_template(nil), do: {:ok, nil}

  def compile_template(str) when is_binary(str) do
    tokens = String.split(str, ".")

    cond do
      Enum.any?(tokens, &(&1 == "")) -> {:error, :empty_template_token}
      Enum.count(tokens, &(&1 == "metric")) != 1 -> {:error, :template_requires_one_metric_token}
      List.last(tokens) != "metric" -> {:error, :metric_token_must_be_last}
      true -> {:ok, tokens}
    end
  end

  @doc "Splits a dotted path into `{metric, labels}` per a compiled template."
  @spec apply_template(String.t(), template() | nil) :: {:ok, String.t(), map()} | :error
  def apply_template(path, nil), do: {:ok, path, %{}}

  def apply_template(path, template) do
    segments = String.split(path, ".")
    prefix = :lists.droplast(template)

    if length(segments) <= length(prefix) do
      :error
    else
      {prefix_segments, metric_segments} = Enum.split(segments, length(prefix))
      {:ok, Enum.join(metric_segments, "."), match_prefix(prefix, prefix_segments)}
    end
  end

  defp match_prefix(prefix, segments) do
    prefix
    |> Enum.zip(segments)
    |> Enum.reduce(%{}, fn
      {"*", _seg}, acc -> acc
      {key, seg}, acc -> Map.put(acc, key, seg)
    end)
  end

  @doc """
  Parses one Graphite plaintext line: `metric value timestamp`.

  Dispatches to Graphite 1.1+ tag syntax (`metric;tag=val;...`) when a
  `;` is present in the metric field, independent of any template;
  otherwise applies `template` to the dotted path.

      parse_line("forklift.FL-07.engine.temp 94.2 1752931200", ["*", "forklift", "metric"])
      #=> {:ok, {"engine.temp", %{"forklift" => "FL-07"}, 94.2, 1752931200}}

  Trailing `\\r` is stripped so CRLF-terminated lines work. Rejects
  malformed field counts, non-numeric values, the literal `"nan"`
  value (used by collectd's `write_graphite` for undefined
  datapoints — `bg_samples.value` is `REAL NOT NULL`, and letting NaN
  through would poison aggregate `SUM`/`AVG`/`MIN`/`MAX`), non-integer
  timestamps (a float-looking timestamp is malformed, not truncated),
  and a metric or label (key or value) that isn't valid UTF-8 — bytes
  straight off the wire, and downstream `JSON.encode!/1` (label
  storage, `Barograph.Writer.insert_series/4`) raises on invalid UTF-8,
  which would otherwise crash the writer process on a single bad line.
  """
  @spec parse_line(String.t(), template() | nil) ::
          {:ok, {String.t(), map(), float(), integer()}} | :error
  def parse_line(line, template) do
    with [metric_field, value_field, ts_field] <-
           line |> String.trim_trailing("\r") |> String.split(),
         {:ok, metric, labels} <- resolve_metric(metric_field, template),
         true <- valid_utf8?(metric, labels),
         {:ok, value} <- parse_value(value_field),
         {:ok, ts} <- parse_ts(ts_field) do
      {:ok, {metric, labels, value, ts}}
    else
      _ -> :error
    end
  end

  defp valid_utf8?(metric, labels) do
    String.valid?(metric) and
      Enum.all?(labels, fn {key, value} -> String.valid?(key) and String.valid?(value) end)
  end

  defp resolve_metric(field, template) do
    if String.contains?(field, ";"), do: parse_tags(field), else: apply_template(field, template)
  end

  defp parse_tags(field) do
    case String.split(field, ";") do
      [metric | tags] when metric != "" and tags != [] -> parse_tag_pairs(tags, metric)
      _ -> :error
    end
  end

  defp parse_tag_pairs(tags, metric) do
    Enum.reduce_while(tags, {:ok, metric, %{}}, fn tag, {:ok, m, acc} ->
      case String.split(tag, "=", parts: 2) do
        [key, value] when key != "" and value != "" ->
          {:cont, {:ok, m, Map.put(acc, key, value)}}

        _ ->
          {:halt, :error}
      end
    end)
  end

  defp parse_value(str) do
    if String.downcase(str) == "nan" do
      :error
    else
      case Float.parse(str) do
        {value, ""} -> {:ok, value}
        _ -> :error
      end
    end
  end

  defp parse_ts(str) do
    case Integer.parse(str) do
      {value, ""} -> {:ok, value}
      _ -> :error
    end
  end
end
