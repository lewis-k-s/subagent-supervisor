defmodule CodexSubagents.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  describe "parse_flags/1" do
    test "parses valid key-value pairs" do
      assert CodexSubagents.CLI.parse_flags(["--owner", "alice", "--cwd", "/tmp"]) ==
               %{"owner" => "alice", "cwd" => "/tmp"}
    end

    test "returns empty map for empty args" do
      assert CodexSubagents.CLI.parse_flags([]) == %{}
    end

    test "parses single flag" do
      assert CodexSubagents.CLI.parse_flags(["--mode", "any"]) == %{"mode" => "any"}
    end
  end

  describe "shell_quote/1" do
    test "leaves safe strings unchanged" do
      assert CodexSubagents.CLI.shell_quote("hello_world.txt") == "hello_world.txt"
    end

    test "quotes strings with spaces and special chars" do
      assert CodexSubagents.CLI.shell_quote("echo 'hello'") == "'echo '\"'\"'hello'\"'\"''"
    end
  end

  describe "parse_mode/1" do
    test "accepts any" do
      assert CodexSubagents.CLI.parse_mode("any") == :any
    end

    test "accepts all" do
      assert CodexSubagents.CLI.parse_mode("all") == :all
    end
  end

  describe "split_csv/1" do
    test "handles empty string" do
      assert CodexSubagents.CLI.split_csv("") == []
    end

    test "handles multiple comma-separated values" do
      assert CodexSubagents.CLI.split_csv("a,b,c") == ["a", "b", "c"]
    end
  end

  describe "session helpers" do
    test "session_owner prefers owner and falls back to session" do
      assert CodexSubagents.CLI.session_owner(%{"owner" => "owner-a", "session" => "session-a"}) ==
               "owner-a"

      assert CodexSubagents.CLI.session_owner(%{"session" => "session-a"}) == "session-a"
      assert CodexSubagents.CLI.session_owner(%{}) == nil
    end

    test "new_session_id returns a short readable slug with random suffix" do
      id = CodexSubagents.CLI.new_session_id("Master Agent")

      assert id =~ ~r/^master-agent-[a-z0-9_-]{7}$/
    end
  end

  describe "normalize_top_terminal_env!/0" do
    setup do
      original_term = System.get_env("TERM")
      original_terminfo = System.get_env("TERMINFO")

      on_exit(fn ->
        restore_env("TERM", original_term)
        restore_env("TERMINFO", original_terminfo)
      end)

      :ok
    end

    test "maps ghostty terminfo to xterm with blank TERMINFO" do
      System.put_env("TERM", "xterm-ghostty")
      System.put_env("TERMINFO", "/Applications/Ghostty.app/Contents/Resources/terminfo")

      CodexSubagents.CLI.normalize_top_terminal_env!()

      assert System.get_env("TERM") == "xterm-256color"
      assert System.get_env("TERMINFO") == ""
    end

    test "maps tmux terminals to xterm with blank Ghostty TERMINFO" do
      System.put_env("TERM", "tmux-256color")
      System.put_env("TERMINFO", "/Applications/Ghostty.app/Contents/Resources/terminfo")

      CodexSubagents.CLI.normalize_top_terminal_env!()

      assert System.get_env("TERM") == "xterm-256color"
      assert System.get_env("TERMINFO") == ""
    end
  end

  describe "main/1" do
    test "help prints usage" do
      output = capture_io(fn -> CodexSubagents.CLI.main([]) end)
      assert output =~ "codex-subagents server"
      assert output =~ "codex-subagents session"
      assert output =~ "codex-subagents start"
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
