defmodule SubagentSupervisor.LauncherTest do
  use ExUnit.Case

  describe "resolve/0" do
    test "falls back to PATH when not running from a source-checkout escript" do
      old_path = System.get_env("PATH")

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "subagent-supervisor-launcher-test-#{System.unique_integer([:positive])}"
        )

      launcher = Path.join(tmp_dir, "claude-subagent")

      File.mkdir_p!(tmp_dir)
      File.write!(launcher, "#!/usr/bin/env sh\n")
      File.chmod!(launcher, 0o755)
      System.put_env("PATH", tmp_dir)

      on_exit(fn ->
        restore_env("PATH", old_path)
        File.rm_rf(tmp_dir)
      end)

      assert SubagentSupervisor.Launcher.resolve() == {:ok, launcher}
    end

    test "returns :error instead of crashing when no launcher can be resolved" do
      old_path = System.get_env("PATH")
      System.put_env("PATH", "")

      on_exit(fn -> restore_env("PATH", old_path) end)

      assert SubagentSupervisor.Launcher.resolve() == :error
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
