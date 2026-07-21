defmodule Barograph.Ingest.Graphite.ParserTest do
  use ExUnit.Case, async: true

  alias Barograph.Ingest.Graphite.Parser

  describe "compile_template/1" do
    test "nil is valid — no template" do
      assert {:ok, nil} = Parser.compile_template(nil)
    end

    test "a valid template compiles to its tokens" do
      assert {:ok, ["*", "forklift", "metric"]} = Parser.compile_template("*.forklift.metric")
    end

    test "requires exactly one metric token" do
      assert {:error, :template_requires_one_metric_token} = Parser.compile_template("*.forklift")

      assert {:error, :template_requires_one_metric_token} =
               Parser.compile_template("metric.forklift.metric")
    end

    test "metric token must be last" do
      assert {:error, :metric_token_must_be_last} = Parser.compile_template("metric.forklift")
    end

    test "rejects empty tokens" do
      assert {:error, :empty_template_token} = Parser.compile_template("foo..metric")
      assert {:error, :empty_template_token} = Parser.compile_template(".metric")
    end
  end

  describe "parse_line/2 — no template" do
    test "whole dotted path is the metric, no labels" do
      assert {:ok, {"engine.temp", %{}, 94.2, 1_752_931_200}} =
               Parser.parse_line("engine.temp 94.2 1752931200", nil)
    end

    test "integer-looking value coerces to float" do
      assert {:ok, {"m", %{}, 94.0, 100}} = Parser.parse_line("m 94 100", nil)
    end

    test "CRLF-terminated line is accepted" do
      assert {:ok, {"m", %{}, 1.0, 100}} = Parser.parse_line("m 1.0 100\r", nil)
    end
  end

  describe "parse_line/2 — with template (spec §10.1 worked example)" do
    setup do
      {:ok, template} = Parser.compile_template("*.forklift.metric")
      %{template: template}
    end

    test "splits into metric and labels", %{template: template} do
      assert {:ok, {"engine.temp", %{"forklift" => "FL-07"}, 94.2, 1_752_931_200}} =
               Parser.parse_line("forklift.FL-07.engine.temp 94.2 1752931200", template)
    end

    test "path shorter than the template prefix is malformed", %{template: template} do
      assert :error = Parser.parse_line("forklift.FL-07 94.2 1752931200", template)
    end
  end

  describe "parse_line/2 — Graphite 1.1+ tag syntax" do
    test "parsed independent of template presence" do
      assert {:ok, {"metric.path", %{"tag1" => "val1", "tag2" => "val2"}, 94.2, 1_752_931_200}} =
               Parser.parse_line("metric.path;tag1=val1;tag2=val2 94.2 1752931200", nil)
    end

    test "wins over a configured template", %{} do
      {:ok, template} = Parser.compile_template("*.forklift.metric")

      assert {:ok, {"metric.path", %{"tag1" => "val1"}, 94.2, 1_752_931_200}} =
               Parser.parse_line("metric.path;tag1=val1 94.2 1752931200", template)
    end

    test "empty tag value is malformed" do
      assert :error = Parser.parse_line("metric.path;tag1= 94.2 1752931200", nil)
    end

    test "empty metric prefix is malformed" do
      assert :error = Parser.parse_line(";tag1=val1 94.2 1752931200", nil)
    end
  end

  describe "parse_line/2 — malformed input" do
    test "wrong field count" do
      assert :error = Parser.parse_line("m 1.0", nil)
      assert :error = Parser.parse_line("m 1.0 100 extra", nil)
    end

    test "non-numeric value" do
      assert :error = Parser.parse_line("m notanumber 100", nil)
    end

    test "nan value is rejected, case-insensitively" do
      assert :error = Parser.parse_line("m nan 100", nil)
      assert :error = Parser.parse_line("m NaN 100", nil)
    end

    test "non-integer timestamp" do
      assert :error = Parser.parse_line("m 1.0 100.5", nil)
      assert :error = Parser.parse_line("m 1.0 notatimestamp", nil)
    end

    test "blank line" do
      assert :error = Parser.parse_line("", nil)
    end

    test "invalid UTF-8 in the metric is rejected, not just passed through" do
      bad = <<"m", 0xFF, 0xFE>>
      refute String.valid?(bad)
      assert :error = Parser.parse_line(bad <> " 1.0 100", nil)
    end

    test "invalid UTF-8 in a tag value is rejected" do
      bad = <<"metric;tag=", 0xFF, 0xFE>>
      assert :error = Parser.parse_line(bad <> " 1.0 100", nil)
    end

    test "invalid UTF-8 in a template-derived label value is rejected" do
      {:ok, template} = Parser.compile_template("*.forklift.metric")
      bad = <<"forklift.", 0xFF, 0xFE, ".engine.temp">>
      assert :error = Parser.parse_line(bad <> " 1.0 100", template)
    end
  end
end
