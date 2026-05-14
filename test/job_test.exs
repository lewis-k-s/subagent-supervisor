defmodule SubagentSupervisor.JobTest do
  use ExUnit.Case, async: true

  test "enforcing required keys raises without :id" do
    assert_raise ArgumentError, fn ->
      struct!(SubagentSupervisor.Job, %{
        owner: "test",
        command: "echo hi",
        cwd: "/tmp",
        status: :queued,
        inserted_at: DateTime.utc_now()
      })
    end
  end

  test "optional fields default to nil" do
    job = %SubagentSupervisor.Job{
      id: "test-id",
      owner: "test",
      command: "echo hi",
      cwd: "/tmp",
      status: :queued,
      inserted_at: DateTime.utc_now()
    }

    assert job.label == nil
    assert job.exit_status == nil
    assert job.output == nil
    assert job.task_ref == nil
    assert job.started_at == nil
    assert job.finished_at == nil
  end
end
