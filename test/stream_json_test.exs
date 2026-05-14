defmodule SubagentSupervisor.StreamJSONTest do
  use ExUnit.Case, async: true

  alias SubagentSupervisor.StreamJSON

  describe "extract_text/1" do
    test "extracts text from a result event" do
      stream =
        json_lines([
          %{"type" => "system", "subtype" => "init", "cwd" => "/tmp"},
          %{
            "type" => "result",
            "subtype" => "success",
            "result" => "Hello, world!",
            "total_cost_usd" => 0.01
          }
        ])

      assert StreamJSON.extract_text(stream) == "Hello, world!"
    end

    test "extracts text from assistant messages when no result event" do
      stream =
        json_lines([
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{"type" => "text", "text" => "First part"},
                %{"type" => "thinking", "thinking" => "internal"}
              ]
            }
          },
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{"type" => "text", "text" => "Second part"}
              ]
            }
          }
        ])

      assert StreamJSON.extract_text(stream) == "First part\nSecond part"
    end

    test "prefers result over assistant messages" do
      stream =
        json_lines([
          %{
            "type" => "assistant",
            "message" => %{"content" => [%{"type" => "text", "text" => "partial"}]}
          },
          %{"type" => "result", "result" => "final answer"}
        ])

      assert StreamJSON.extract_text(stream) == "final answer"
    end

    test "passes through plain text when no valid JSON-lines" do
      assert StreamJSON.extract_text("hello world") == "hello world"
    end

    test "passes through plain text with newlines" do
      assert StreamJSON.extract_text("line one\nline two\nline three") ==
               "line one\nline two\nline three"
    end

    test "passes through mixed content with no result or assistant events" do
      stream =
        json_lines([
          %{"type" => "system", "subtype" => "init"},
          %{"type" => "unknown", "data" => 42}
        ])

      assert StreamJSON.extract_text(stream) == stream
    end

    test "handles empty string" do
      assert StreamJSON.extract_text("") == ""
    end

    test "extracts from realistic Claude CLI stream-json output" do
      stream = """
      {"type":"system","subtype":"init","cwd":"/tmp","session_id":"abc"}
      {"type":"stream_event","event":{"type":"message_start","message":{"id":"msg1","role":"assistant","content":[]}}}
      {"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}
      {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello!"}}}
      {"type":"assistant","message":{"id":"msg1","role":"assistant","content":[{"type":"text","text":"Hello!"}]}}
      {"type":"stream_event","event":{"type":"content_block_stop","index":0}}
      {"type":"stream_event","event":{"type":"message_stop"}}
      {"type":"result","subtype":"success","result":"Hello!","total_cost_usd":0.05}
      """

      assert StreamJSON.extract_text(stream) == "Hello!"
    end
  end

  describe "format_incremental/2" do
    test "returns empty tagged list when no new content" do
      assert StreamJSON.format_incremental("hello", 5) == {[], 5}
      assert StreamJSON.format_incremental("hello", 10) == {[], 10}
    end

    test "extracts text from streaming text_delta events" do
      content =
        json_lines([
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => "Hi "}
            }
          },
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => "there!"}
            }
          }
        ])

      {tagged, offset} = StreamJSON.format_incremental(content, 0)
      assert tagged == [{"Hi there!", nil}]
      assert offset == byte_size(content)
    end

    test "skips thinking_delta events" do
      content =
        json_lines([
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "thinking_delta", "thinking" => "internal thought"}
            }
          },
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 1,
              "delta" => %{"type" => "text_delta", "text" => "visible"}
            }
          }
        ])

      {tagged, _offset} = StreamJSON.format_incremental(content, 0)
      assert tagged == [{"visible", nil}]
    end

    test "formats tool_use block starts" do
      content =
        json_lines([
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_start",
              "index" => 0,
              "content_block" => %{"type" => "tool_use", "name" => "Bash"}
            }
          }
        ])

      {tagged, _offset} = StreamJSON.format_incremental(content, 0)
      assert tagged == [{"\n[Tool: Bash]\n", nil}]
    end

    test "handles incomplete trailing lines safely" do
      complete =
        json_lines([
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => "ok"}
            }
          }
        ])

      incomplete = ~s({"type":"stream_event","event":{"type":"content_block_delta")

      content = complete <> incomplete

      {tagged, offset} = StreamJSON.format_incremental(content, 0)
      assert tagged == [{"ok", nil}]
      assert offset == byte_size(complete)
    end

    test "processes incomplete line on subsequent call" do
      chunk1 =
        json_lines([
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => "first"}
            }
          }
        ])

      incomplete =
        ~s({"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"second"}})

      content_after_chunk1 = chunk1 <> incomplete
      {tagged1, offset1} = StreamJSON.format_incremental(content_after_chunk1, 0)
      assert tagged1 == [{"first", nil}]

      content_final = content_after_chunk1 <> ~s(})
      {tagged2, offset2} = StreamJSON.format_incremental(content_final, offset1)
      assert tagged2 == [{"second", nil}]
      assert offset2 == byte_size(content_final)
    end

    test "assistant text-only snapshots are suppressed in incremental output" do
      content =
        json_lines([
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => "Hello"}
            }
          },
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [%{"type" => "text", "text" => "Hello"}]
            }
          },
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => " world"}
            }
          }
        ])

      {tagged, _offset} = StreamJSON.format_incremental(content, 0)
      assert tagged == [{"Hello world", nil}]
    end

    test "formats incremental output from offset" do
      prefix =
        json_lines([
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => "old"}
            }
          }
        ])

      suffix =
        json_lines([
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => " new"}
            }
          }
        ])

      full = prefix <> suffix

      {tagged, _offset} = StreamJSON.format_incremental(full, byte_size(prefix))
      assert tagged == [{" new", nil}]
    end

    test "assistant tool_use snapshots show input details" do
      content =
        json_lines([
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "echo hello"}}
              ]
            }
          }
        ])

      {tagged, _offset} = StreamJSON.format_incremental(content, 0)
      assert tagged == [{~s([Tool: Bash] $ echo hello), nil}]
    end

    test "assistant tool_use snapshots show file path for Edit" do
      content =
        json_lines([
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "name" => "Edit",
                  "input" => %{"file_path" => "/tmp/test.ex"}
                }
              ]
            }
          }
        ])

      {tagged, _offset} = StreamJSON.format_incremental(content, 0)
      assert tagged == [{~s([Tool: Edit] /tmp/test.ex), nil}]
    end

    test "assistant tool_use snapshots show file path for Read" do
      content =
        json_lines([
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "name" => "Read",
                  "input" => %{"file_path" => "lib/foo.ex"}
                }
              ]
            }
          }
        ])

      {tagged, _offset} = StreamJSON.format_incremental(content, 0)
      assert tagged == [{~s([Tool: Read] lib/foo.ex), nil}]
    end

    test "assistant tool_use with unknown tool shows JSON input" do
      content =
        json_lines([
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{"type" => "tool_use", "name" => "Custom", "input" => %{"key" => "val"}}
              ]
            }
          }
        ])

      {tagged, _offset} = StreamJSON.format_incremental(content, 0)
      assert tagged == [{~s([Tool: Custom] {"key":"val"}), nil}]
    end

    test "assistant tool_use with empty input shows name only" do
      content =
        json_lines([
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{"type" => "tool_use", "name" => "Bash", "input" => %{}}
              ]
            }
          }
        ])

      {tagged, _offset} = StreamJSON.format_incremental(content, 0)
      assert tagged == [{~s([Tool: Bash]), nil}]
    end

    test "user tool errors show as red tagged lines" do
      content =
        json_lines([
          %{
            "type" => "user",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_result",
                  "is_error" => true,
                  "content" => "Tool execution denied"
                }
              ]
            }
          }
        ])

      {tagged, _offset} = StreamJSON.format_incremental(content, 0)
      assert tagged == [{"Tool execution denied", :red}]
    end

    test "user tool errors with block content show as red" do
      content =
        json_lines([
          %{
            "type" => "user",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_result",
                  "is_error" => true,
                  "content" => [%{"type" => "text", "text" => "Permission denied"}]
                }
              ]
            }
          }
        ])

      {tagged, _offset} = StreamJSON.format_incremental(content, 0)
      assert tagged == [{"Permission denied", :red}]
    end

    test "user non-error tool results are suppressed" do
      content =
        json_lines([
          %{
            "type" => "user",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_result",
                  "content" => "normal output"
                }
              ]
            }
          }
        ])

      {tagged, _offset} = StreamJSON.format_incremental(content, 0)
      assert tagged == []
    end
  end

  describe "extract_verbose/1" do
    test "shows session, thinking, text, tool_use, tool result, and result" do
      stream =
        json_lines([
          %{
            "type" => "system",
            "subtype" => "init",
            "model" => "GLM-5.1",
            "session_id" => "abc12345def"
          },
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "message_start",
              "message" => %{"role" => "assistant", "content" => []}
            }
          },
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "delta" => %{"type" => "thinking_delta", "thinking" => "ignored"}
            }
          },
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{"type" => "thinking", "thinking" => "I should use a tool."}
              ]
            }
          },
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "name" => "Bash",
                  "input" => %{"command" => "echo hello"}
                }
              ]
            }
          },
          %{
            "type" => "user",
            "message" => %{
              "content" => [
                %{"type" => "tool_result", "content" => "hello\n"}
              ]
            }
          },
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [%{"type" => "text", "text" => "The output is hello."}]
            }
          },
          %{
            "type" => "result",
            "result" => "The output is hello.",
            "total_cost_usd" => 0.05,
            "duration_ms" => 3500,
            "usage" => %{"input_tokens" => 1000, "output_tokens" => 50}
          }
        ])

      text = StreamJSON.extract_verbose(stream)
      assert text =~ "[session] model=GLM-5.1 session=abc12345"
      assert text =~ "[thinking] I should use a tool."
      assert text =~ "[Tool: Bash]"
      assert text =~ "echo hello"
      assert text =~ "[tool result] hello"
      assert text =~ "[assistant] The output is hello."
      assert text =~ "[result] The output is hello."
      assert text =~ "$0.0500"
      assert text =~ "3.5s"
      assert text =~ "1000in/50out"
      refute text =~ "thinking_delta"
      refute text =~ "message_start"
      refute text =~ "content_block_delta"
    end

    test "filters out all envelope and delta events" do
      stream =
        json_lines([
          %{
            "type" => "stream_event",
            "event" => %{"type" => "message_start", "message" => %{"content" => []}}
          },
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_start",
              "content_block" => %{"type" => "text", "text" => ""}
            }
          },
          %{
            "type" => "stream_event",
            "event" => %{
              "type" => "content_block_delta",
              "delta" => %{"type" => "text_delta", "text" => "Hi"}
            }
          },
          %{
            "type" => "stream_event",
            "event" => %{"type" => "content_block_stop"}
          },
          %{
            "type" => "stream_event",
            "event" => %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}}
          },
          %{
            "type" => "stream_event",
            "event" => %{"type" => "message_stop"}
          }
        ])

      text = StreamJSON.extract_verbose(stream)
      assert text == stream
    end

    test "passes through non-JSON content unchanged" do
      assert StreamJSON.extract_verbose("plain text output") == "plain text output"
    end

    test "handles multi-turn tool use with user messages" do
      stream =
        json_lines([
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "name" => "Read",
                  "input" => %{"file_path" => "/tmp/test.ex"}
                }
              ]
            }
          },
          %{
            "type" => "user",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_result",
                  "content" => [%{"type" => "text", "text" => "file contents here"}]
                }
              ]
            }
          },
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [%{"type" => "text", "text" => "I read the file."}]
            }
          },
          %{
            "type" => "result",
            "result" => "I read the file.",
            "total_cost_usd" => 0.1,
            "duration_ms" => 10000,
            "usage" => %{"input_tokens" => 5000, "output_tokens" => 100}
          }
        ])

      text = StreamJSON.extract_verbose(stream)
      assert text =~ "[Tool: Read]"
      assert text =~ "file contents here"
      assert text =~ "[assistant] I read the file."
      assert text =~ "10.0s"
    end
  end

  defp json_lines(objects) do
    objects
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end
end
