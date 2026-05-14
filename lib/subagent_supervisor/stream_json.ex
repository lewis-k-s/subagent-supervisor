defmodule SubagentSupervisor.StreamJSON do
  @moduledoc """
  Parses Claude CLI stream-json output into human-readable text.

  Claude CLI emits newline-delimited JSON when run with
  `--output-format stream-json --include-partial-messages`.  Each line is one
  of:

    * `{"type":"system",...}`                — init metadata
    * `{"type":"stream_event","event":...}`  — streaming deltas
    * `{"type":"assistant","message":...}`   — partial message snapshots
    * `{"type":"user","message":...}`        — tool result messages
    * `{"type":"result","result":"...",...}` — final result with cost stats

  When the input is **not** valid JSON-lines (e.g. plain bash output in test
  mode), every function falls back to returning the raw content unchanged.
  """

  alias SubagentSupervisor.StreamJSON.Event

  @doc """
  Extracts the final text result from a completed stream-json capture.

  Strategy (first match wins):

    1. The `"type":"result"` line's `"result"` field.
    2. Concatenated `"text"` blocks from `"type":"assistant"` messages.
    3. Raw content passthrough (no valid JSON-lines found).

  Returns the extracted text.
  """
  @spec extract_text(String.t()) :: String.t()
  def extract_text(content) when is_binary(content) do
    lines = String.split(content, "\n", trim: true)

    case find_result_text(lines) do
      {:ok, text} ->
        text

      :not_found ->
        case collect_assistant_text(lines) do
          "" -> content
          text -> text
        end
    end
  end

  defp find_result_text(lines) do
    Enum.find_value(lines, :not_found, fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "result", "result" => result}} when is_binary(result) ->
          {:ok, result}

        _ ->
          nil
      end
    end)
  end

  defp collect_assistant_text(lines) do
    lines
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "assistant", "message" => %{"content" => content}}}
        when is_list(content) ->
          content
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map(& &1["text"])

        _ ->
          []
      end
    end)
    |> Enum.join("\n")
  end

  @doc """
  Formats the full stream-json capture into a verbose, filtered summary.

  Whitelist — only these event types are rendered:

    * `system`           → model + session id
    * `assistant`        → thinking blocks, text blocks, tool_use (name + input)
    * `user`             → tool result content
    * `result`           → result text + cost + duration + token counts

  Everything else (`content_block_delta`, `content_block_start/stop`,
  `message_start/stop/delta`) is suppressed.
  """
  @spec extract_verbose(String.t()) :: String.t()
  def extract_verbose(content) when is_binary(content) do
    lines = String.split(content, "\n", trim: true)

    text =
      lines
      |> Enum.map(&Event.format_verbose/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    if text == "", do: content, else: text
  end

  @doc """
  Formats new stream events that arrived since byte offset `prev_offset`.

  Returns `{readable_text, new_offset}` where `new_offset` tracks the byte
  position of the last complete line processed (incomplete trailing bytes are
  held back until the next call).

  Used by `tail --follow` to render human-readable output incrementally.
  """
  @spec format_incremental(String.t(), non_neg_integer()) ::
          {[{String.t(), atom() | nil}], non_neg_integer()}
  def format_incremental(content, prev_offset) when is_binary(content) do
    do_format_incremental(content, prev_offset, &Event.format/1, true)
  end

  @doc """
  Incremental verbose-mode formatter. Same as `format_incremental/2` but uses
  `Event.format_verbose/1` per line instead of `Event.format/1`.
  """
  @spec format_verbose_incremental(String.t(), non_neg_integer()) ::
          {[{String.t(), atom() | nil}], non_neg_integer()}
  def format_verbose_incremental(content, prev_offset) when is_binary(content) do
    do_format_incremental(content, prev_offset, &Event.format_verbose/1, false)
  end

  defp do_format_incremental(content, prev_offset, formatter, merge?) do
    len = byte_size(content)

    if len <= prev_offset do
      {[], prev_offset}
    else
      new_bytes = binary_part(content, prev_offset, len - prev_offset)
      parts = String.split(new_bytes, "\n")

      {complete_lines, incomplete} =
        case List.last(parts) do
          "" ->
            {Enum.drop(parts, -1), ""}

          last ->
            if decodable?(last) do
              {parts, ""}
            else
              {Enum.drop(parts, -1), last}
            end
        end

      tagged_raw =
        complete_lines
        |> Enum.map(formatter)
        |> Enum.map(&to_tagged/1)
        |> Enum.reject(fn {t, _} -> t == "" end)

      tagged = if merge?, do: merge_consecutive(tagged_raw), else: tagged_raw

      new_offset = len - byte_size(incomplete)
      {tagged, new_offset}
    end
  end

  defp to_tagged({text, color}), do: {text, color}
  defp to_tagged(text) when is_binary(text), do: {text, nil}

  defp merge_consecutive(tagged) do
    tagged
    |> Enum.reduce([], fn {text, color}, acc ->
      case acc do
        [{prev, ^color} | rest] -> [{prev <> text, color} | rest]
        _ -> [{text, color} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp decodable?(line) do
    case Jason.decode(line) do
      {:ok, _} -> true
      _ -> false
    end
  end
end

defmodule SubagentSupervisor.StreamJSON.Event do
  @moduledoc false

  def format(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "stream_event", "event" => event}} ->
        {format_stream_event(event), nil}

      {:ok, %{"type" => "assistant", "message" => %{"content" => content}}}
      when is_list(content) ->
        {format_assistant_tools(content), nil}

      {:ok, %{"type" => "user", "message" => %{"content" => content}}}
      when is_list(content) ->
        format_user_errors(content)

      _ ->
        {"", nil}
    end
  end

  defp format_stream_event(%{"type" => "content_block_delta", "delta" => delta}) do
    case delta do
      %{"type" => "text_delta", "text" => text} -> text
      _ -> ""
    end
  end

  defp format_stream_event(%{"type" => "content_block_start", "content_block" => block}) do
    case block do
      %{"type" => "tool_use", "name" => name} ->
        "\n[Tool: #{name}]\n"

      _ ->
        ""
    end
  end

  defp format_stream_event(_), do: ""

  defp format_assistant_tools(content) do
    content
    |> Enum.filter(&(&1["type"] == "tool_use"))
    |> Enum.map(&format_tool_with_input/1)
    |> Enum.join("\n")
  end

  defp format_tool_with_input(%{"name" => name, "input" => input}) do
    detail =
      case {name, input} do
        {"Bash", %{"command" => cmd}} -> " $ #{cmd}"
        {"Edit", %{"file_path" => p}} -> " #{p}"
        {"Read", %{"file_path" => p}} -> " #{p}"
        {"Write", %{"file_path" => p}} -> " #{p}"
        {_, m} when map_size(m) > 0 -> " #{Jason.encode!(m)}"
        _ -> ""
      end

    "[Tool: #{name}]#{detail}"
  end

  defp format_user_errors(content) do
    errors =
      Enum.filter(content, fn
        %{"type" => "tool_result", "is_error" => true} -> true
        _ -> false
      end)

    case errors do
      [] ->
        {"", nil}

      _ ->
        text =
          errors
          |> Enum.map(&extract_tool_result_text/1)
          |> Enum.join("\n")

        {text, :red}
    end
  end

  defp extract_tool_result_text(%{"content" => inner}) when is_binary(inner), do: inner

  defp extract_tool_result_text(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => t} -> [t]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp extract_tool_result_text(_), do: ""

  @doc """
  Verbose-mode formatter. Applies the whitelist to produce a readable
  summary from assembled snapshots rather than streaming deltas.
  """
  def format_verbose(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "system"} = event} ->
        format_system(event)

      {:ok, %{"type" => "assistant", "message" => %{"content" => content}}}
      when is_list(content) ->
        format_assistant(content)

      {:ok, %{"type" => "user", "message" => %{"content" => content}}}
      when is_list(content) ->
        format_user(content)

      {:ok, %{"type" => "result"} = event} ->
        format_result(event)

      _ ->
        ""
    end
  end

  defp format_system(event) do
    model = Map.get(event, "model", "?")
    sid = Map.get(event, "session_id", "?")

    if sid != "?" do
      "[session] model=#{model} session=#{String.slice(sid, 0, 8)}"
    else
      ""
    end
  end

  defp format_assistant(content) do
    content
    |> Enum.map(&format_content_block/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_content_block(%{"type" => "thinking", "thinking" => text})
       when is_binary(text) and text != "" do
    "[thinking] #{text}"
  end

  defp format_content_block(%{"type" => "text", "text" => text})
       when is_binary(text) and text != "" do
    "[assistant] #{text}"
  end

  defp format_content_block(%{"type" => "tool_use", "name" => name, "input" => input}) do
    input_str = Jason.encode!(input)
    "[Tool: #{name}] #{input_str}"
  end

  defp format_content_block(_), do: ""

  defp format_user(content) do
    texts =
      content
      |> Enum.flat_map(fn
        %{"type" => "tool_result", "content" => inner} when is_binary(inner) ->
          [inner]

        %{"type" => "tool_result", "content" => blocks} when is_list(blocks) ->
          blocks
          |> Enum.flat_map(fn
            %{"type" => "text", "text" => t} -> [t]
            _ -> []
          end)

        _ ->
          []
      end)

    case texts do
      [] -> ""
      _ -> "[tool result] #{Enum.join(texts, "\n")}"
    end
  end

  defp format_result(event) do
    result = Map.get(event, "result", "")
    cost = Map.get(event, "total_cost_usd", 0)
    duration_ms = Map.get(event, "duration_ms", 0)

    usage = Map.get(event, "usage", %{})
    in_tok = Map.get(usage, "input_tokens", 0)
    out_tok = Map.get(usage, "output_tokens", 0)

    duration_s =
      if duration_ms > 0 do
        Float.round(duration_ms / 1000, 1)
      else
        0.0
      end

    "[result] #{result} | $#{format_cost(cost)} | #{duration_s}s | #{in_tok}in/#{out_tok}out"
  end

  defp format_cost(cost) when is_float(cost) do
    :erlang.float_to_binary(cost, decimals: 4)
  end

  defp format_cost(cost), do: to_string(cost)
end
