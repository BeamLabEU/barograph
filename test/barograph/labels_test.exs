defmodule Barograph.LabelsTest do
  use ExUnit.Case, async: true

  alias Barograph.Labels

  test "canonical sorts keys and joins with NUL separators" do
    assert Labels.canonical(%{b: "2", a: "1"}) == "a=1\x00b=2"
  end

  test "canonical of empty labels is the empty string" do
    assert Labels.canonical(%{}) == ""
  end

  test "hash is 16 bytes and deterministic" do
    labels = %{forklift: "FL-07", site: "tallinn"}
    assert byte_size(Labels.hash(labels)) == 16
    assert Labels.hash(labels) == Labels.hash(%{site: "tallinn", forklift: "FL-07"})
  end

  test "different label sets produce different hashes" do
    assert Labels.hash(%{a: "1"}) != Labels.hash(%{a: "2"})
  end
end
