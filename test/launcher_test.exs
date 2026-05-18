defmodule SubagentSupervisor.LauncherTest do
  use ExUnit.Case

  @launcher Path.expand("../scripts/claude-subagent", __DIR__)

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

  describe "claude-subagent script" do
    test "uses SUBAGENT_SUPERVISOR_CWD for sandbox settings instead of process cwd" do
      old_path = System.get_env("PATH")
      old_tmpdir = System.get_env("TMPDIR")
      old_config_dir = System.get_env("CLAUDE_SUBAGENT_CONFIG_DIR")
      old_supervisor_cwd = System.get_env("SUBAGENT_SUPERVISOR_CWD")
      old_codex_sandbox = System.get_env("CODEX_SANDBOX")
      old_codex_shell = System.get_env("CODEX_SHELL")
      old_inherited_sandbox = System.get_env("SUBAGENT_SUPERVISOR_INHERITED_SANDBOX")

      base =
        Path.join(
          System.tmp_dir!(),
          "subagent-supervisor-launcher-script-test-#{System.unique_integer([:positive])}"
        )

      process_cwd = Path.join(base, "process-cwd")
      job_cwd = Path.join(base, "job-cwd")
      bin_dir = Path.join(base, "bin")
      config_dir = Path.join(base, "claude-config")
      fake_claude = Path.join(bin_dir, "claude")

      File.mkdir_p!(process_cwd)
      File.mkdir_p!(job_cwd)
      File.mkdir_p!(bin_dir)
      File.write!(fake_claude, "#!/usr/bin/env sh\nexit 0\n")
      File.chmod!(fake_claude, 0o755)

      path =
        [bin_dir, old_path]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(":")

      System.put_env("PATH", path)
      System.put_env("TMPDIR", base)
      System.put_env("CLAUDE_SUBAGENT_CONFIG_DIR", config_dir)
      System.put_env("SUBAGENT_SUPERVISOR_CWD", job_cwd)
      System.delete_env("CODEX_SANDBOX")
      System.delete_env("CODEX_SHELL")
      System.delete_env("SUBAGENT_SUPERVISOR_INHERITED_SANDBOX")

      on_exit(fn ->
        restore_env("PATH", old_path)
        restore_env("TMPDIR", old_tmpdir)
        restore_env("CLAUDE_SUBAGENT_CONFIG_DIR", old_config_dir)
        restore_env("SUBAGENT_SUPERVISOR_CWD", old_supervisor_cwd)
        restore_env("CODEX_SANDBOX", old_codex_sandbox)
        restore_env("CODEX_SHELL", old_codex_shell)
        restore_env("SUBAGENT_SUPERVISOR_INHERITED_SANDBOX", old_inherited_sandbox)
        File.rm_rf(base)
      end)

      assert {_, 0} = System.cmd(@launcher, ["noop"], cd: process_cwd)

      settings = File.read!(Path.join(config_dir, "subagent-settings.json"))
      assert settings =~ json_string(real_dir(job_cwd))
      refute settings =~ json_string(real_dir(process_cwd))
    end

    test "omits outside cwd from allowWrite when sandbox write roots are set" do
      old_path = System.get_env("PATH")
      old_tmpdir = System.get_env("TMPDIR")
      old_config_dir = System.get_env("CLAUDE_SUBAGENT_CONFIG_DIR")
      old_supervisor_cwd = System.get_env("SUBAGENT_SUPERVISOR_CWD")
      old_write_roots = System.get_env("SUBAGENT_SUPERVISOR_SANDBOX_WRITE_ROOTS")
      old_cwd_writable = System.get_env("SUBAGENT_SUPERVISOR_CWD_WRITABLE")
      old_codex_sandbox = System.get_env("CODEX_SANDBOX")
      old_codex_shell = System.get_env("CODEX_SHELL")
      old_inherited_sandbox = System.get_env("SUBAGENT_SUPERVISOR_INHERITED_SANDBOX")

      base =
        Path.join(
          System.tmp_dir!(),
          "subagent-supervisor-launcher-script-test-#{System.unique_integer([:positive])}"
        )

      allowed_root = Path.join(base, "allowed")
      job_cwd = Path.join(base, "outside")
      bin_dir = Path.join(base, "bin")
      config_dir = Path.join(base, "claude-config")
      fake_claude = Path.join(bin_dir, "claude")

      File.mkdir_p!(allowed_root)
      File.mkdir_p!(job_cwd)
      File.mkdir_p!(bin_dir)
      File.write!(fake_claude, "#!/usr/bin/env sh\nexit 0\n")
      File.chmod!(fake_claude, 0o755)

      path =
        [bin_dir, old_path]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(":")

      System.put_env("PATH", path)
      System.put_env("TMPDIR", base)
      System.put_env("CLAUDE_SUBAGENT_CONFIG_DIR", config_dir)
      System.put_env("SUBAGENT_SUPERVISOR_CWD", job_cwd)
      System.put_env("SUBAGENT_SUPERVISOR_SANDBOX_WRITE_ROOTS", allowed_root)
      System.delete_env("SUBAGENT_SUPERVISOR_CWD_WRITABLE")
      System.delete_env("CODEX_SANDBOX")
      System.delete_env("CODEX_SHELL")
      System.delete_env("SUBAGENT_SUPERVISOR_INHERITED_SANDBOX")

      on_exit(fn ->
        restore_env("PATH", old_path)
        restore_env("TMPDIR", old_tmpdir)
        restore_env("CLAUDE_SUBAGENT_CONFIG_DIR", old_config_dir)
        restore_env("SUBAGENT_SUPERVISOR_CWD", old_supervisor_cwd)
        restore_env("SUBAGENT_SUPERVISOR_SANDBOX_WRITE_ROOTS", old_write_roots)
        restore_env("SUBAGENT_SUPERVISOR_CWD_WRITABLE", old_cwd_writable)
        restore_env("CODEX_SANDBOX", old_codex_sandbox)
        restore_env("CODEX_SHELL", old_codex_shell)
        restore_env("SUBAGENT_SUPERVISOR_INHERITED_SANDBOX", old_inherited_sandbox)
        File.rm_rf(base)
      end)

      assert {_, 0} = System.cmd(@launcher, ["noop"], cd: allowed_root)

      settings = File.read!(Path.join(config_dir, "subagent-settings.json"))
      refute settings =~ ~s("allowWrite": [#{json_string(real_dir(job_cwd))})
      assert settings =~ json_string(base)
    end

    test "keeps Claude sandbox enabled when server did not inherit Codex sandbox" do
      old_path = System.get_env("PATH")
      old_tmpdir = System.get_env("TMPDIR")
      old_config_dir = System.get_env("CLAUDE_SUBAGENT_CONFIG_DIR")
      old_supervisor_cwd = System.get_env("SUBAGENT_SUPERVISOR_CWD")
      old_cwd_writable = System.get_env("SUBAGENT_SUPERVISOR_CWD_WRITABLE")
      old_server_inherited = System.get_env("SUBAGENT_SUPERVISOR_SERVER_SANDBOX_INHERITED")
      old_codex_sandbox = System.get_env("CODEX_SANDBOX")
      old_codex_shell = System.get_env("CODEX_SHELL")

      base =
        Path.join(
          System.tmp_dir!(),
          "subagent-supervisor-launcher-script-test-#{System.unique_integer([:positive])}"
        )

      job_cwd = Path.join(base, "job-cwd")
      bin_dir = Path.join(base, "bin")
      config_dir = Path.join(base, "claude-config")
      fake_claude = Path.join(bin_dir, "claude")

      File.mkdir_p!(job_cwd)
      File.mkdir_p!(bin_dir)
      File.write!(fake_claude, "#!/usr/bin/env sh\nexit 0\n")
      File.chmod!(fake_claude, 0o755)

      path =
        [bin_dir, old_path]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(":")

      System.put_env("PATH", path)
      System.put_env("TMPDIR", base)
      System.put_env("CLAUDE_SUBAGENT_CONFIG_DIR", config_dir)
      System.put_env("SUBAGENT_SUPERVISOR_CWD", job_cwd)
      System.put_env("SUBAGENT_SUPERVISOR_CWD_WRITABLE", "1")
      System.put_env("SUBAGENT_SUPERVISOR_SERVER_SANDBOX_INHERITED", "0")
      System.put_env("CODEX_SANDBOX", "seatbelt")
      System.delete_env("CODEX_SHELL")

      on_exit(fn ->
        restore_env("PATH", old_path)
        restore_env("TMPDIR", old_tmpdir)
        restore_env("CLAUDE_SUBAGENT_CONFIG_DIR", old_config_dir)
        restore_env("SUBAGENT_SUPERVISOR_CWD", old_supervisor_cwd)
        restore_env("SUBAGENT_SUPERVISOR_CWD_WRITABLE", old_cwd_writable)
        restore_env("SUBAGENT_SUPERVISOR_SERVER_SANDBOX_INHERITED", old_server_inherited)
        restore_env("CODEX_SANDBOX", old_codex_sandbox)
        restore_env("CODEX_SHELL", old_codex_shell)
        File.rm_rf(base)
      end)

      assert {_, 0} = System.cmd(@launcher, ["noop"], cd: job_cwd)

      settings = File.read!(Path.join(config_dir, "subagent-settings.json"))
      assert settings =~ ~s("enabled": true)
      refute settings == "{ \"sandbox\": { \"enabled\": false } }\n"
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp json_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> then(&~s("#{&1}"))
  end

  defp real_dir(path) do
    File.cd!(path, &File.cwd!/0)
  end
end
