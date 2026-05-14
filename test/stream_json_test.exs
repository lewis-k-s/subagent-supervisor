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
    test "returns empty text when no new content" do
      assert StreamJSON.format_incremental("hello", 5) == {"", 5}
      assert StreamJSON.format_incremental("hello", 10) == {"", 10}
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

      {text, offset} = StreamJSON.format_incremental(content, 0)
      assert text == "Hi there!"
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

      {text, _offset} = StreamJSON.format_incremental(content, 0)
      assert text == "visible"
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

      {text, _offset} = StreamJSON.format_incremental(content, 0)
      assert text == "\n[Tool: Bash]\n"
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

      {text, offset} = StreamJSON.format_incremental(content, 0)
      assert text == "ok"
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
      {text1, offset1} = StreamJSON.format_incremental(content_after_chunk1, 0)
      assert text1 == "first"

      content_final = content_after_chunk1 <> ~s(})
      {text2, offset2} = StreamJSON.format_incremental(content_final, offset1)
      assert text2 == "second"
      assert offset2 == byte_size(content_final)
    end

    test "assistant message snapshots are suppressed in incremental output" do
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

      {text, _offset} = StreamJSON.format_incremental(content, 0)
      assert text == "Hello world"
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

      {text, _offset} = StreamJSON.format_incremental(full, byte_size(prefix))
      assert text == " new"
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
