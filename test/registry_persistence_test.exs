defmodule SubagentSupervisor.Registry.PersistenceTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias SubagentSupervisor.Job
  alias SubagentSupervisor.Registry.Persistence

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "registry-persistence-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  test "missing snapshot loads empty job list", %{dir: dir} do
    assert {:ok, []} = Persistence.load(dir)
  end

  test "save and load round-trips durable job state", %{dir: dir} do
    now = DateTime.utc_now()

    job = %Job{
      id: "job_roundtrip",
      owner: "owner",
      command: "bash -c 'printf ok'",
      cwd: File.cwd!(),
      label: "label",
      agent: nil,
      sandbox_write_roots: [],
      sandbox_write_bounded: false,
      cwd_writable: true,
      server_sandbox: %{inherited: false, kind: :none, write_roots: [], source: :none},
      status: :succeeded,
      exit_status: 0,
      output: "ok",
      output_path: Persistence.log_path(dir, "job_roundtrip"),
      session_id: "session",
      task_ref: make_ref(),
      inserted_at: now,
      started_at: now,
      finished_at: now
    }

    assert :ok = Persistence.save!(dir, %{job.id => job})
    assert {:ok, [loaded]} = Persistence.load(dir)

    assert loaded.id == job.id
    assert loaded.status == :succeeded
    assert loaded.output == "ok"
    assert loaded.task_ref == nil
  end

  test "corrupt snapshot is quarantined and loads empty", %{dir: dir} do
    File.mkdir_p!(dir)
    path = Path.join(dir, "registry.etf")
    File.write!(path, "not an etf")

    log =
      capture_log(fn ->
        assert {:ok, []} = Persistence.load(dir)
      end)

    refute File.exists?(path)
    assert log =~ "corrupt registry snapshot"
    assert dir |> File.ls!() |> Enum.any?(&String.starts_with?(&1, "registry.etf.corrupt-"))
  end
end
