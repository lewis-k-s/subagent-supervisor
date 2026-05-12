defmodule CodexSubagents.JSON do
  @moduledoc """
  Minimal zero-dependency JSON encoder supporting maps, lists, strings, atoms,
  numbers, booleans, nil, and DateTime.
  """

  def encode(value), do: do_encode(value)

  defp do_encode(%DateTime{} = value), do: do_encode(DateTime.to_iso8601(value))

  defp do_encode(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _inner} -> to_string(key) end)
    |> Enum.map(fn {key, inner} -> do_encode(to_string(key)) <> ":" <> do_encode(inner) end)
    |> Enum.join(",")
    |> then(&("{" <> &1 <> "}"))
  end

  defp do_encode(value) when is_list(value) do
    value
    |> Enum.map(&do_encode/1)
    |> Enum.join(",")
    |> then(&("[" <> &1 <> "]"))
  end

  defp do_encode(nil), do: "null"
  defp do_encode(true), do: "true"
  defp do_encode(false), do: "false"
  defp do_encode(value) when is_atom(value), do: do_encode(to_string(value))
  defp do_encode(value) when is_binary(value), do: "\"" <> escape(value) <> "\""
  defp do_encode(value) when is_integer(value), do: Integer.to_string(value)
  defp do_encode(value) when is_float(value), do: Float.to_string(value)

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end
end
