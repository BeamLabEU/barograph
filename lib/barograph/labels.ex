defmodule Barograph.Labels do
  @moduledoc """
  Label canonicalisation and series hashing (spec §5.1).

  Keys are sorted, each entry rendered as `key=value`, and entries are
  joined with `\\x00` separators. The canonical string is hashed with
  BLAKE2b truncated to 16 bytes. Deterministic across nodes and restarts.
  """

  @sep <<0>>
  @hash_bytes 16

  @doc "Renders a label map into its canonical string form."
  @spec canonical(map()) :: binary()
  def canonical(labels) when is_map(labels) do
    labels
    |> Enum.sort()
    |> Enum.map_join(@sep, fn {key, value} -> "#{key}=#{value}" end)
  end

  @doc "Returns the 16-byte BLAKE2b hash of the canonicalised labels."
  @spec hash(map()) :: <<_::128>>
  def hash(labels) when is_map(labels) do
    binary_part(:crypto.hash(:blake2b, canonical(labels)), 0, @hash_bytes)
  end
end
