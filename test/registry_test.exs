defmodule SubagentSupervisor.RegistryTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  setup context do
    max_concurrency = Map.get(context, :max_concurrency, 2)

    # Restart app if GenServer crashed in a prior test
    unless Process.whereis(SubagentSupervisor.Registry) do
      Application.stop(:subagent_supervisor)
    end

    Application.ensure_all_started(:subagent_supervisor)
    :ok = SubagentSupervisor.Registry.reset_for_test(max_concurrency)
    :ok
  end

  test "starts and waits for a bash job" do
    assert {:ok, job} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "thread-1",
               "command" => "bash -c 'printf hello'",
               "cwd" => File.cwd!()
             })

    assert {:ok, [finished]} = SubagentSupervisor.Registry.wait("thread-1", [job.id], :all, 5_000)
    assert finished.status == :succeeded
    assert finished.exit_status == 0
    assert finished.output == "hello"
  end

  test "sets job cwd in subprocess environment" do
    cwd =
      Path.join(
        System.tmp_dir!(),
        "subagent-supervisor-cwd-env-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(cwd)

    on_exit(fn -> File.rm_rf(cwd) end)

    assert {:ok, job} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "cwd-env-test",
               "command" =>
                 "bash -c 'printf \"%s|%s\" \"$SUBAGENT_SUPERVISOR_CWD\" \"$(pwd -P)\"'",
               "cwd" => cwd
             })

    assert {:ok, [finished]} =
             SubagentSupervisor.Registry.wait("cwd-env-test", [job.id], :all, 5_000)

    assert finished.status == :succeeded

    [env_cwd, port_cwd] = String.split(finished.output, "|", parts: 2)
    assert env_cwd == cwd
    assert Path.basename(port_cwd) == Path.basename(cwd)
  end

  test "start_job confirms accepted observable jobs" do
    assert {:ok, job} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "accepted-test",
               "command" => "bash -c 'printf accepted'",
               "cwd" => File.cwd!()
             })

    assert job.accepted == true
    assert job.observable == true
    assert {:ok, found} = SubagentSupervisor.Registry.show(job.id)
    assert found.accepted == true
    assert found.observable == true
  end

  test "wait any returns the first completed job for an owner" do
    assert {:ok, _slow} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "thread-2",
               "command" => "bash -c 'sleep 1; printf slow'",
               "cwd" => File.cwd!()
             })

    assert {:ok, fast} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "thread-2",
               "command" => "bash -c 'printf fast'",
               "cwd" => File.cwd!()
             })

    assert {:ok, [finished]} = SubagentSupervisor.Registry.wait("thread-2", [], :any, 5_000)
    assert finished.id == fast.id
    assert finished.output == "fast"
  end

  @tag max_concurrency: 1
  test "queues jobs beyond max concurrency" do
    assert {:ok, running} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "thread-3",
               "command" => "bash -c 'sleep 1; printf first'",
               "cwd" => File.cwd!()
             })

    assert {:ok, queued} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "thread-3",
               "command" => "bash -c 'printf second'",
               "cwd" => File.cwd!()
             })

    assert running.status == :running
    assert queued.status == :queued

    assert {:ok, [first, second]} = SubagentSupervisor.Registry.wait("thread-3", [], :all, 5_000)
    assert first.output == "first"
    assert second.output == "second"
  end

  test "start_job returns error on missing owner" do
    assert {:error, "missing required owner"} =
             SubagentSupervisor.Registry.start_job(%{
               "command" => "bash -c 'echo hi'",
               "cwd" => File.cwd!()
             })
  end

  test "start_job returns error on missing command" do
    assert {:error, "missing required command"} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "test",
               "cwd" => File.cwd!()
             })
  end

  test "show returns not_found for unknown id" do
    assert {:error, :not_found} = SubagentSupervisor.Registry.show("nonexistent")
  end

  test "show without --full omits output" do
    assert {:ok, job} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "show-no-output",
               "command" => "bash -c 'printf hello'",
               "cwd" => File.cwd!()
             })

    assert {:ok, [_]} = SubagentSupervisor.Registry.wait("show-no-output", [job.id], :all, 5_000)
    assert {:ok, found} = SubagentSupervisor.Registry.show(job.id)
    refute Map.has_key?(found, :output)
  end

  test "show with include_output: true returns full output" do
    assert {:ok, job} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "show-full-output",
               "command" => "bash -c 'printf hello'",
               "cwd" => File.cwd!()
             })

    assert {:ok, [_]} =
             SubagentSupervisor.Registry.wait("show-full-output", [job.id], :all, 5_000)

    assert {:ok, found} = SubagentSupervisor.Registry.show(job.id, include_output: true)
    assert found.output == "hello"
  end

  test "list filters by owner; list(nil) returns all" do
    SubagentSupervisor.Registry.start_job(%{
      "owner" => "alpha",
      "command" => "bash -c 'printf a'",
      "cwd" => File.cwd!()
    })

    SubagentSupervisor.Registry.start_job(%{
      "owner" => "beta",
      "command" => "bash -c 'printf b'",
      "cwd" => File.cwd!()
    })

    assert {:ok, alpha_jobs} = SubagentSupervisor.Registry.list("alpha")
    assert length(alpha_jobs) == 1
    assert hd(alpha_jobs).owner == "alpha"

    assert {:ok, all_jobs} = SubagentSupervisor.Registry.list(nil)
    assert length(all_jobs) == 2
  end

  test "failed job gets status failed with exit_status" do
    assert {:ok, _job} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "fail-test",
               "command" => "bash -c 'exit 1'",
               "cwd" => File.cwd!()
             })

    assert {:ok, [finished]} = SubagentSupervisor.Registry.wait("fail-test", [], :all, 5_000)
    assert finished.status == :failed
    assert finished.exit_status == 1
  end

  test "wait :all times out" do
    assert {:ok, _job} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "timeout-test",
               "command" => "bash -c 'sleep 10'",
               "cwd" => File.cwd!()
             })

    assert {:error, :timeout} =
             SubagentSupervisor.Registry.wait("timeout-test", [], :all, 50)
  end

  test "wait :any returns immediately if a matching job already finished" do
    assert {:ok, job} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "any-done",
               "command" => "bash -c 'printf done'",
               "cwd" => File.cwd!()
             })

    assert {:ok, [_]} = SubagentSupervisor.Registry.wait("any-done", [job.id], :all, 5_000)

    assert {:ok, [finished]} = SubagentSupervisor.Registry.wait("any-done", [], :any, 5_000)
    assert finished.status == :succeeded
  end

  test "custom id via attrs is preserved" do
    assert {:ok, job} =
             SubagentSupervisor.Registry.start_job(%{
               "id" => "my-custom-id",
               "owner" => "custom-id",
               "command" => "bash -c 'printf custom'",
               "cwd" => File.cwd!()
             })

    assert job.id == "my-custom-id"
    assert {:ok, found} = SubagentSupervisor.Registry.show("my-custom-id")
    assert found.id == "my-custom-id"
  end

  test "label round-trips through start and wait" do
    assert {:ok, _job} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "label-test",
               "label" => "my-label",
               "command" => "bash -c 'printf labeled'",
               "cwd" => File.cwd!()
             })

    assert {:ok, [finished]} = SubagentSupervisor.Registry.wait("label-test", [], :all, 5_000)
    assert finished.label == "my-label"
  end

  test "owner isolation - two owners do not cross-contaminate" do
    assert {:ok, _a} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "owner-a",
               "command" => "bash -c 'printf a'",
               "cwd" => File.cwd!()
             })

    assert {:ok, _b} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "owner-b",
               "command" => "bash -c 'printf b'",
               "cwd" => File.cwd!()
             })

    assert {:ok, [a]} = SubagentSupervisor.Registry.wait("owner-a", [], :all, 5_000)
    assert a.output == "a"

    assert {:ok, [b]} = SubagentSupervisor.Registry.wait("owner-b", [], :all, 5_000)
    assert b.output == "b"
  end

  test "reset_for_test clears all state" do
    SubagentSupervisor.Registry.start_job(%{
      "owner" => "reset-test",
      "command" => "bash -c 'sleep 60'",
      "cwd" => File.cwd!()
    })

    assert {:ok, jobs_before} = SubagentSupervisor.Registry.list(nil)
    assert length(jobs_before) == 1

    :ok = SubagentSupervisor.Registry.reset_for_test(2)

    assert {:ok, jobs_after} = SubagentSupervisor.Registry.list(nil)
    assert jobs_after == []
  end

  test "dashboard_state returns grouped jobs and concurrency stats" do
    SubagentSupervisor.Registry.start_job(%{
      "owner" => "alpha",
      "command" => "bash -c 'printf a'",
      "cwd" => File.cwd!()
    })

    SubagentSupervisor.Registry.start_job(%{
      "owner" => "beta",
      "command" => "bash -c 'sleep 60'",
      "cwd" => File.cwd!()
    })

    assert {:ok, state} = SubagentSupervisor.Registry.dashboard_state()

    assert state.total_jobs == 2
    assert state.max_concurrency == 2
    assert %DateTime{} = state.started_at
    assert is_list(state.supervision_tree)
    assert length(state.supervision_tree) == 1

    assert length(state.jobs_by_owner) == 2
    owners = Enum.map(state.jobs_by_owner, & &1.owner)
    assert "alpha" in owners
    assert "beta" in owners

    assert is_integer(state.running)
    assert is_integer(state.queued)
  end

  test "dashboard_state supervision tree has expected structure" do
    assert {:ok, state} = SubagentSupervisor.Registry.dashboard_state()

    [sup] = state.supervision_tree
    assert sup.name == "SubagentSupervisor.Supervisor"
    assert sup.type == :supervisor
    assert is_list(sup.children)

    child_names = Enum.map(sup.children, & &1.name)
    assert "SubagentSupervisor.TaskSupervisor" in child_names
    assert "SubagentSupervisor.Registry" in child_names
  end

  test "read_output returns output for a completed job" do
    assert {:ok, job} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "read-output",
               "command" => "bash -c 'printf \"hello world\"'",
               "cwd" => File.cwd!()
             })

    assert {:ok, [finished]} =
             SubagentSupervisor.Registry.wait("read-output", [job.id], :all, 5_000)

    assert finished.status == :succeeded

    assert {:ok, output} = SubagentSupervisor.Registry.read_output(job.id)
    assert output == "hello world"
  end

  test "read_output returns partial output for a running job" do
    assert {:ok, job} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "partial-output",
               "command" => "bash -c 'printf started; sleep 10; printf done'",
               "cwd" => File.cwd!()
             })

    Process.sleep(500)

    assert {:ok, output} = SubagentSupervisor.Registry.read_output(job.id)
    assert output == "started"
  end

  test "read_output returns error for unknown id" do
    assert {:error, :not_found} = SubagentSupervisor.Registry.read_output("nonexistent")
  end

  test "stderr is captured in output" do
    assert {:ok, job} =
             SubagentSupervisor.Registry.start_job(%{
               "owner" => "stderr-test",
               "command" => "bash -c 'printf stdout; printf stderr >&2'",
               "cwd" => File.cwd!()
             })

    assert {:ok, [finished]} =
             SubagentSupervisor.Registry.wait("stderr-test", [job.id], :all, 5_000)

    assert finished.output =~ "stdout"
    assert finished.output =~ "stderr"
  end

  describe "status" do
    test "returns not_found for unknown id" do
      assert {:error, :not_found} = SubagentSupervisor.Registry.status("nonexistent")
    end

    test "returns metadata and output digest for a completed job" do
      assert {:ok, job} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "status-done",
                 "command" => "bash -c 'printf \"hello world\"'",
                 "cwd" => File.cwd!()
               })

      assert {:ok, [_]} =
               SubagentSupervisor.Registry.wait("status-done", [job.id], :all, 5_000)

      assert {:ok, result} = SubagentSupervisor.Registry.status(job.id)
      assert result.id == job.id
      assert result.status == :succeeded
      assert result.owner == "status-done"
      assert result.output_digest == "hello world"
      assert %DateTime{} = result.started_at
      assert %DateTime{} = result.finished_at
    end

    test "returns partial output digest for a running job" do
      assert {:ok, job} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "status-running",
                 "command" => "bash -c 'printf started; sleep 10; printf done'",
                 "cwd" => File.cwd!()
               })

      Process.sleep(500)

      assert {:ok, result} = SubagentSupervisor.Registry.status(job.id)
      assert result.status == :running
      assert result.output_digest == "started"
    end

    test "truncates long output" do
      assert {:ok, job} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "status-long",
                 "command" => "bash -c 'python3 -c \"print(chr(120) * 5000)\"'",
                 "cwd" => File.cwd!()
               })

      assert {:ok, [_]} =
               SubagentSupervisor.Registry.wait("status-long", [job.id], :all, 5_000)

      assert {:ok, result} = SubagentSupervisor.Registry.status(job.id)
      digest = result.output_digest
      assert String.contains?(digest, "[truncated]")
    end
  end

  describe "command validation" do
    test "rejects commands that do not start with an allowed launcher" do
      assert {:error, reason} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "validate-test",
                 "command" => "/usr/bin/python3 -c 'print(1)'",
                 "cwd" => File.cwd!()
               })

      assert reason =~ "command rejected"
      assert Process.whereis(SubagentSupervisor.Registry)
    end

    test "rejects launcher followed by semicolon (shell injection)" do
      assert {:error, reason} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "validate-test",
                 "command" => "bash; echo injected",
                 "cwd" => File.cwd!()
               })

      assert reason =~ "command rejected"
      assert Process.whereis(SubagentSupervisor.Registry)
    end

    test "accepts launcher followed by a space and arguments" do
      assert {:ok, _job} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "validate-test",
                 "command" => "bash -c 'echo ok'",
                 "cwd" => File.cwd!()
               })
    end

    test "accepts bare launcher without arguments" do
      assert {:ok, _job} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "validate-test",
                 "command" => "bash",
                 "cwd" => File.cwd!()
               })
    end

    test "rejects cwd that is not an existing directory" do
      missing = Path.join(System.tmp_dir!(), "missing-cwd-#{System.unique_integer([:positive])}")

      assert {:error, reason} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "validate-test",
                 "command" => "bash -c 'printf no'",
                 "cwd" => missing
               })

      assert reason =~ "cwd must be an existing directory"
      assert Process.whereis(SubagentSupervisor.Registry)
    end

    test "rejects write-capable agents outside sandbox write roots" do
      log =
        capture_log(
          fn ->
            assert {:error, reason} =
                     SubagentSupervisor.Registry.start_job(%{
                       "owner" => "validate-test",
                       "command" => "bash -c 'printf denied'",
                       "agent" => "sweng-coder",
                       "cwd" => File.cwd!(),
                       "sandbox_write_roots" => [System.tmp_dir!()]
                     })

            assert reason =~ "requires write access"
          end,
          level: :info
        )

      assert log =~ "subagent launch rejected"
      assert log =~ "agent=\"sweng-coder\""
      assert Process.whereis(SubagentSupervisor.Registry)
    end

    test "allows exploration agents outside sandbox write roots as read-only cwd" do
      assert {:ok, job} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "validate-test",
                 "command" => "bash -c 'printf readonly'",
                 "agent" => "Explore",
                 "cwd" => File.cwd!(),
                 "sandbox_write_roots" => [System.tmp_dir!()]
               })

      assert job.cwd_writable == false
    end

    test "passes cwd writable policy to subprocess environment" do
      assert {:ok, job} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "validate-test",
                 "command" =>
                   "bash -c 'printf \"%s|%s\" \"$SUBAGENT_SUPERVISOR_CWD_WRITABLE\" \"$SUBAGENT_SUPERVISOR_SANDBOX_WRITE_ROOTS\"'",
                 "cwd" => File.cwd!(),
                 "sandbox_write_roots" => [System.tmp_dir!()]
               })

      assert {:ok, [finished]} =
               SubagentSupervisor.Registry.wait("validate-test", [job.id], :all, 5_000)

      assert finished.output == "0|#{Path.expand(System.tmp_dir!())}"
    end

    test "intersects client write roots with inherited server sandbox roots" do
      old_server_roots = System.get_env("SUBAGENT_SUPERVISOR_SERVER_SANDBOX_WRITE_ROOTS")
      old_inherited = System.get_env("SUBAGENT_SUPERVISOR_INHERITED_SANDBOX")
      old_codex_sandbox = System.get_env("CODEX_SANDBOX")
      old_codex_shell = System.get_env("CODEX_SHELL")

      System.put_env("SUBAGENT_SUPERVISOR_SERVER_SANDBOX_WRITE_ROOTS", System.tmp_dir!())
      System.put_env("SUBAGENT_SUPERVISOR_INHERITED_SANDBOX", "1")
      System.delete_env("CODEX_SANDBOX")
      System.delete_env("CODEX_SHELL")

      Application.stop(:subagent_supervisor)
      Application.ensure_all_started(:subagent_supervisor)
      :ok = SubagentSupervisor.Registry.reset_for_test(2)

      on_exit(fn ->
        restore_env("SUBAGENT_SUPERVISOR_SERVER_SANDBOX_WRITE_ROOTS", old_server_roots)
        restore_env("SUBAGENT_SUPERVISOR_INHERITED_SANDBOX", old_inherited)
        restore_env("CODEX_SANDBOX", old_codex_sandbox)
        restore_env("CODEX_SHELL", old_codex_shell)
        Application.stop(:subagent_supervisor)
        Application.ensure_all_started(:subagent_supervisor)
      end)

      assert {:ok, job} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "validate-test",
                 "command" => "bash -c 'printf constrained'",
                 "agent" => "Explore",
                 "cwd" => File.cwd!(),
                 "sandbox_write_roots" => [File.cwd!()]
               })

      assert job.cwd_writable == false
      assert job.sandbox_write_roots == []
      assert job.sandbox_write_bounded == true
      assert job.server_sandbox.inherited == true
      assert job.server_sandbox.write_roots == [Path.expand(System.tmp_dir!())]
    end
  end

  describe "agent support" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "agents-reg-test-#{System.unique_integer([:positive])}")
      user_home = Path.join(tmp, "home")
      File.mkdir_p!(Path.join(user_home, ".claude/agents"))

      write_agent(Path.join([user_home, ".claude", "agents", "test-agent.md"]), %{
        "name" => "test-agent",
        "description" => "Test agent"
      })

      old_home = System.get_env("HOME")
      System.put_env("HOME", user_home)

      on_exit(fn ->
        restore_env("HOME", old_home)
        File.rm_rf!(tmp)
      end)

      :ok
    end

    test "start_job stores agent on job and returns it" do
      assert {:ok, job} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "agent-test",
                 "command" => "bash -c 'printf hello'",
                 "agent" => "test-agent",
                 "cwd" => File.cwd!()
               })

      assert job.agent == "test-agent"
    end

    test "start_job without agent stores nil" do
      assert {:ok, job} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "no-agent-test",
                 "command" => "bash -c 'printf hello'",
                 "cwd" => File.cwd!()
               })

      assert job.agent == nil
    end

    test "start_job returns error on unknown agent" do
      assert {:error, reason} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "bad-agent",
                 "command" => "bash -c 'printf hello'",
                 "agent" => "nonexistent-agent",
                 "cwd" => File.cwd!()
               })

      assert reason =~ "unknown agent: nonexistent-agent"
      assert Process.whereis(SubagentSupervisor.Registry)
    end

    test "public_job includes agent field" do
      assert {:ok, job} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "pub-agent",
                 "command" => "bash -c 'printf hi'",
                 "agent" => "test-agent",
                 "cwd" => File.cwd!()
               })

      assert {:ok, [finished]} =
               SubagentSupervisor.Registry.wait("pub-agent", [job.id], :all, 5_000)

      assert finished.agent == "test-agent"
    end
  end

  describe "session_id storage" do
    test "session_id is nil on newly created jobs" do
      assert {:ok, job} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "session-test",
                 "command" => "bash -c 'printf hello'",
                 "cwd" => File.cwd!()
               })

      assert job.session_id == nil
    end

    test "session_id is extracted from stream-json output on completion" do
      # Use a bash command that produces JSON output with a session_id
      json_line =
        Jason.encode!(%{
          "type" => "system",
          "subtype" => "init",
          "session_id" => "test-session-123"
        })

      assert {:ok, job} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "session-extract",
                 "command" => "bash -c 'printf #{shell_escape(json_line)}'",
                 "cwd" => File.cwd!()
               })

      assert {:ok, [finished]} =
               SubagentSupervisor.Registry.wait("session-extract", [job.id], :all, 5_000)

      assert finished.session_id == "test-session-123"
    end

    test "public_job includes session_id" do
      assert {:ok, job} =
               SubagentSupervisor.Registry.start_job(%{
                 "owner" => "pub-session",
                 "command" => "bash -c 'printf hello'",
                 "cwd" => File.cwd!()
               })

      assert {:ok, [finished]} =
               SubagentSupervisor.Registry.wait("pub-session", [job.id], :all, 5_000)

      assert Map.has_key?(finished, :session_id)
    end
  end

  describe "register" do
    test "creates a job with registered status and session_id" do
      assert {:ok, job} =
               SubagentSupervisor.Registry.register(%{
                 "owner" => "register-test",
                 "session_id" => "abc-123-def",
                 "cwd" => File.cwd!()
               })

      assert job.status == :registered
      assert job.session_id == "abc-123-def"
      assert job.owner == "register-test"
      assert job.command == nil
    end

    test "registered job appears in list" do
      SubagentSupervisor.Registry.register(%{
        "owner" => "register-list",
        "session_id" => "list-session-id",
        "label" => "planner",
        "cwd" => File.cwd!()
      })

      assert {:ok, jobs} = SubagentSupervisor.Registry.list("register-list")
      assert length(jobs) == 1
      assert hd(jobs).status == :registered
      assert hd(jobs).session_id == "list-session-id"
      assert hd(jobs).label == "planner"
    end

    test "registered job is discoverable via show" do
      assert {:ok, job} =
               SubagentSupervisor.Registry.register(%{
                 "owner" => "register-show",
                 "session_id" => "show-session-id",
                 "cwd" => File.cwd!()
               })

      assert {:ok, found} = SubagentSupervisor.Registry.show(job.id)
      assert found.status == :registered
      assert found.session_id == "show-session-id"
    end

    test "registered job is considered terminal for wait" do
      assert {:ok, _job} =
               SubagentSupervisor.Registry.register(%{
                 "owner" => "register-wait",
                 "session_id" => "wait-session-id",
                 "cwd" => File.cwd!()
               })

      assert {:ok, [finished]} =
               SubagentSupervisor.Registry.wait("register-wait", [], :all, 1_000)

      assert finished.status == :registered
    end

    test "register raises on missing owner" do
      assert catch_exit(
               SubagentSupervisor.Registry.register(%{
                 "session_id" => "some-id",
                 "cwd" => File.cwd!()
               })
             )
    end

    test "status includes session_id for registered job" do
      assert {:ok, job} =
               SubagentSupervisor.Registry.register(%{
                 "owner" => "register-status",
                 "session_id" => "status-session-id",
                 "cwd" => File.cwd!()
               })

      assert {:ok, result} = SubagentSupervisor.Registry.status(job.id)
      assert result.session_id == "status-session-id"
    end
  end

  defp write_agent(path, frontmatter) do
    fm_lines =
      Enum.map(frontmatter, fn {k, v} -> "#{k}: #{v}" end)
      |> Enum.join("\n")

    File.write!(path, "---\n#{fm_lines}\n---\nAgent body")
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp shell_escape(str) do
    str
    |> String.replace("'", "'\\''")
    |> then(&"'#{&1}'")
  end
end
