defmodule CodexSubagents.RegistryTest do
  use ExUnit.Case

  setup context do
    max_concurrency = Map.get(context, :max_concurrency, 2)

    # Restart app if GenServer crashed in a prior test
    unless Process.whereis(CodexSubagents.Registry) do
      Application.stop(:codex_subagents)
    end

    Application.ensure_all_started(:codex_subagents)
    :ok = CodexSubagents.Registry.reset_for_test(max_concurrency)
    :ok
  end

  test "starts and waits for a bash job" do
    assert {:ok, job} =
             CodexSubagents.Registry.start_job(%{
               "owner" => "thread-1",
               "command" => "printf hello",
               "cwd" => File.cwd!()
             })

    assert {:ok, [finished]} = CodexSubagents.Registry.wait("thread-1", [job.id], :all, 5_000)
    assert finished.status == :succeeded
    assert finished.exit_status == 0
    assert finished.output == "hello"
  end

  test "wait any returns the first completed job for an owner" do
    assert {:ok, _slow} =
             CodexSubagents.Registry.start_job(%{
               "owner" => "thread-2",
               "command" => "sleep 1; printf slow",
               "cwd" => File.cwd!()
             })

    assert {:ok, fast} =
             CodexSubagents.Registry.start_job(%{
               "owner" => "thread-2",
               "command" => "printf fast",
               "cwd" => File.cwd!()
             })

    assert {:ok, [finished]} = CodexSubagents.Registry.wait("thread-2", [], :any, 5_000)
    assert finished.id == fast.id
    assert finished.output == "fast"
  end

  @tag max_concurrency: 1
  test "queues jobs beyond max concurrency" do
    assert {:ok, running} =
             CodexSubagents.Registry.start_job(%{
               "owner" => "thread-3",
               "command" => "sleep 1; printf first",
               "cwd" => File.cwd!()
             })

    assert {:ok, queued} =
             CodexSubagents.Registry.start_job(%{
               "owner" => "thread-3",
               "command" => "printf second",
               "cwd" => File.cwd!()
             })

    assert running.status == :running
    assert queued.status == :queued

    assert {:ok, [first, second]} = CodexSubagents.Registry.wait("thread-3", [], :all, 5_000)
    assert first.output == "first"
    assert second.output == "second"
  end

  test "start_job raises on missing owner" do
    assert catch_exit(
             CodexSubagents.Registry.start_job(%{
               "command" => "echo hi",
               "cwd" => File.cwd!()
             })
           )
  end

  test "start_job raises on missing command" do
    assert catch_exit(
             CodexSubagents.Registry.start_job(%{
               "owner" => "test",
               "cwd" => File.cwd!()
             })
           )
  end

  test "show returns not_found for unknown id" do
    assert {:error, :not_found} = CodexSubagents.Registry.show("nonexistent")
  end

  test "list filters by owner; list(nil) returns all" do
    CodexSubagents.Registry.start_job(%{
      "owner" => "alpha",
      "command" => "printf a",
      "cwd" => File.cwd!()
    })

    CodexSubagents.Registry.start_job(%{
      "owner" => "beta",
      "command" => "printf b",
      "cwd" => File.cwd!()
    })

    assert {:ok, alpha_jobs} = CodexSubagents.Registry.list("alpha")
    assert length(alpha_jobs) == 1
    assert hd(alpha_jobs).owner == "alpha"

    assert {:ok, all_jobs} = CodexSubagents.Registry.list(nil)
    assert length(all_jobs) == 2
  end

  test "failed job gets status failed with exit_status" do
    assert {:ok, _job} =
             CodexSubagents.Registry.start_job(%{
               "owner" => "fail-test",
               "command" => "exit 1",
               "cwd" => File.cwd!()
             })

    assert {:ok, [finished]} = CodexSubagents.Registry.wait("fail-test", [], :all, 5_000)
    assert finished.status == :failed
    assert finished.exit_status == 1
  end

  test "wait :all times out" do
    assert {:ok, _job} =
             CodexSubagents.Registry.start_job(%{
               "owner" => "timeout-test",
               "command" => "sleep 10",
               "cwd" => File.cwd!()
             })

    assert {:error, :timeout} =
             CodexSubagents.Registry.wait("timeout-test", [], :all, 50)
  end

  test "wait :any returns immediately if a matching job already finished" do
    assert {:ok, job} =
             CodexSubagents.Registry.start_job(%{
               "owner" => "any-done",
               "command" => "printf done",
               "cwd" => File.cwd!()
             })

    assert {:ok, [_]} = CodexSubagents.Registry.wait("any-done", [job.id], :all, 5_000)

    assert {:ok, [finished]} = CodexSubagents.Registry.wait("any-done", [], :any, 5_000)
    assert finished.status == :succeeded
  end

  test "custom id via attrs is preserved" do
    assert {:ok, job} =
             CodexSubagents.Registry.start_job(%{
               "id" => "my-custom-id",
               "owner" => "custom-id",
               "command" => "printf custom",
               "cwd" => File.cwd!()
             })

    assert job.id == "my-custom-id"
    assert {:ok, found} = CodexSubagents.Registry.show("my-custom-id")
    assert found.id == "my-custom-id"
  end

  test "label round-trips through start and wait" do
    assert {:ok, _job} =
             CodexSubagents.Registry.start_job(%{
               "owner" => "label-test",
               "label" => "my-label",
               "command" => "printf labeled",
               "cwd" => File.cwd!()
             })

    assert {:ok, [finished]} = CodexSubagents.Registry.wait("label-test", [], :all, 5_000)
    assert finished.label == "my-label"
  end

  test "owner isolation - two owners do not cross-contaminate" do
    assert {:ok, _a} =
             CodexSubagents.Registry.start_job(%{
               "owner" => "owner-a",
               "command" => "printf a",
               "cwd" => File.cwd!()
             })

    assert {:ok, _b} =
             CodexSubagents.Registry.start_job(%{
               "owner" => "owner-b",
               "command" => "printf b",
               "cwd" => File.cwd!()
             })

    assert {:ok, [a]} = CodexSubagents.Registry.wait("owner-a", [], :all, 5_000)
    assert a.output == "a"

    assert {:ok, [b]} = CodexSubagents.Registry.wait("owner-b", [], :all, 5_000)
    assert b.output == "b"
  end

  test "reset_for_test clears all state" do
    CodexSubagents.Registry.start_job(%{
      "owner" => "reset-test",
      "command" => "sleep 60",
      "cwd" => File.cwd!()
    })

    assert {:ok, jobs_before} = CodexSubagents.Registry.list(nil)
    assert length(jobs_before) == 1

    :ok = CodexSubagents.Registry.reset_for_test(2)

    assert {:ok, jobs_after} = CodexSubagents.Registry.list(nil)
    assert jobs_after == []
  end

  test "dashboard_state returns grouped jobs and concurrency stats" do
    CodexSubagents.Registry.start_job(%{
      "owner" => "alpha",
      "command" => "printf a",
      "cwd" => File.cwd!()
    })

    CodexSubagents.Registry.start_job(%{
      "owner" => "beta",
      "command" => "sleep 60",
      "cwd" => File.cwd!()
    })

    assert {:ok, state} = CodexSubagents.Registry.dashboard_state()

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
    assert {:ok, state} = CodexSubagents.Registry.dashboard_state()

    [sup] = state.supervision_tree
    assert sup.name == "CodexSubagents.Supervisor"
    assert sup.type == :supervisor
    assert is_list(sup.children)

    child_names = Enum.map(sup.children, & &1.name)
    assert "CodexSubagents.TaskSupervisor" in child_names
    assert "CodexSubagents.Registry" in child_names
  end

  test "read_output returns output for a completed job" do
    assert {:ok, job} =
             CodexSubagents.Registry.start_job(%{
               "owner" => "read-output",
               "command" => "printf 'hello world'",
               "cwd" => File.cwd!()
             })

    assert {:ok, [finished]} = CodexSubagents.Registry.wait("read-output", [job.id], :all, 5_000)
    assert finished.status == :succeeded

    assert {:ok, output} = CodexSubagents.Registry.read_output(job.id)
    assert output == "hello world"
  end

  test "read_output returns partial output for a running job" do
    assert {:ok, job} =
             CodexSubagents.Registry.start_job(%{
               "owner" => "partial-output",
               "command" => "printf 'started'; sleep 10; printf 'done'",
               "cwd" => File.cwd!()
             })

    Process.sleep(500)

    assert {:ok, output} = CodexSubagents.Registry.read_output(job.id)
    assert output == "started"
  end

  test "read_output returns error for unknown id" do
    assert {:error, :not_found} = CodexSubagents.Registry.read_output("nonexistent")
  end

  test "stderr is captured in output" do
    assert {:ok, job} =
             CodexSubagents.Registry.start_job(%{
               "owner" => "stderr-test",
               "command" => "printf stdout; printf stderr >&2",
               "cwd" => File.cwd!()
             })

    assert {:ok, [finished]} = CodexSubagents.Registry.wait("stderr-test", [job.id], :all, 5_000)
    assert finished.output =~ "stdout"
    assert finished.output =~ "stderr"
  end
end
