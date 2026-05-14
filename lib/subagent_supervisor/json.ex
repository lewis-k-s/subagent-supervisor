defmodule SubagentSupervisor.JSON do
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
    |> String.replace("\b", "\\b")
    |> String.replace("\f", "\\f")
    |> escape_control_chars()
  end

  defp escape_control_chars(<<>>), do: ""

  for c <-
        :binary.bin_to_list(
          <<0, 1, 2, 3, 4, 5, 6, 11, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
            29, 30, 31>>
        ) do
    hex = c |> Integer.to_string(16) |> String.pad_leading(4, "0")

    defp escape_control_chars(<<unquote(c), rest::binary>>) do
      "\\u#{unquote(hex)}" <> escape_control_chars(rest)
    end
  end

  defp escape_control_chars(<<c, rest::binary>>) when c >= 32 do
    <<c, escape_control_chars(rest)::binary>>
  end
end
