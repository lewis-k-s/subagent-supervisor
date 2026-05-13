defmodule CodexSubagents.TopTest do
  use ExUnit.Case

  alias CodexSubagents.Top
  alias Ratatouille.Renderer
  alias Ratatouille.Renderer.Canvas

  describe "init/1" do
    test "initializes from Ratatouille window context using configured daemon" do
      Application.put_env(:codex_subagents, :top_daemon, :configured_daemon)

      on_exit(fn ->
        Application.delete_env(:codex_subagents, :top_daemon)
      end)

      model = Top.init(%{window: %{width: 93, height: 44}})

      assert model.daemon == :configured_daemon
      assert model.error =~ "daemon unreachable"
    end

    test "still accepts explicit daemon context" do
      model = Top.init(%{daemon: :explicit_daemon})

      assert model.daemon == :explicit_daemon
      assert model.error =~ "daemon unreachable"
    end
  end

  describe "status_icon/1" do
    test "returns bullet for running" do
      assert Top.status_icon(:running) == "\u25CF"
    end

    test "returns circle for queued" do
      assert Top.status_icon(:queued) == "\u25CB"
    end

    test "returns checkmark for succeeded" do
      assert Top.status_icon(:succeeded) == "\u2713"
    end

    test "returns cross for failed" do
      assert Top.status_icon(:failed) == "\u2717"
    end
  end

  describe "status_color/1" do
    test "maps statuses to colors" do
      assert Top.status_color(:running) == :yellow
      assert Top.status_color(:queued) == :white
      assert Top.status_color(:succeeded) == :green
      assert Top.status_color(:failed) == :red
    end

    test "defaults to white" do
      assert Top.status_color(:unknown) == :white
    end
  end

  describe "format_duration/1" do
    test "returns empty string for queued jobs" do
      assert Top.format_duration(%{status: :queued}) == ""
    end

    test "formats seconds" do
      started = DateTime.utc_now() |> DateTime.add(-30, :second)
      finished = DateTime.utc_now()

      assert Top.format_duration(%{
               status: :succeeded,
               started_at: started,
               finished_at: finished
             }) ==
               "30s"
    end

    test "formats minutes and seconds" do
      started = DateTime.utc_now() |> DateTime.add(-125, :second)
      finished = DateTime.utc_now()

      assert Top.format_duration(%{
               status: :succeeded,
               started_at: started,
               finished_at: finished
             }) ==
               "2m5s"
    end

    test "formats hours and minutes" do
      started = DateTime.utc_now() |> DateTime.add(-3720, :second)
      finished = DateTime.utc_now()

      assert Top.format_duration(%{
               status: :succeeded,
               started_at: started,
               finished_at: finished
             }) ==
               "1h2m"
    end

    test "uses current time for running jobs without finished_at" do
      started = DateTime.utc_now() |> DateTime.add(-5, :second)

      result = Top.format_duration(%{status: :running, started_at: started, finished_at: nil})
      assert String.ends_with?(result, "s")
    end

    test "returns empty for nil started_at" do
      assert Top.format_duration(%{status: :running, started_at: nil, finished_at: nil}) == ""
    end
  end

  describe "format_uptime/1" do
    test "returns unknown for nil" do
      assert Top.format_uptime(nil) == "unknown"
    end

    test "formats seconds" do
      started = DateTime.utc_now() |> DateTime.add(-45, :second)
      assert Top.format_uptime(started) == "45s"
    end

    test "formats minutes and seconds" do
      started = DateTime.utc_now() |> DateTime.add(-185, :second)
      assert Top.format_uptime(started) == "3m5s"
    end

    test "formats hours and minutes" do
      started = DateTime.utc_now() |> DateTime.add(-7320, :second)
      assert Top.format_uptime(started) == "2h2m"
    end
  end

  describe "truncate_id/1" do
    test "truncates job_ prefixed ids" do
      assert Top.truncate_id("job_aBcDeFgH") == "job_aBcDe.."
    end

    test "truncates non-job ids to 10 chars" do
      assert Top.truncate_id("very-long-identifier-here") == "very-long-"
    end
  end

  describe "truncate_command/1" do
    test "keeps short commands" do
      assert Top.truncate_command("mix test") == "mix test"
    end

    test "truncates long commands with ellipsis" do
      long_cmd = String.duplicate("a", 50)
      result = Top.truncate_command(long_cmd)
      assert byte_size(result) == 40
      assert String.ends_with?(result, "...")
    end
  end

  describe "format_pid_short/1" do
    test "formats not started" do
      assert Top.format_pid_short("not started") == "(not started)"
    end

    test "wraps pid in parens" do
      assert Top.format_pid_short("#PID<0.123.0>") == "(#PID<0.123.0>)"
    end
  end

  describe "update/2" do
    test "arrow up decrements scroll offset with floor at 0" do
      model = %Top{daemon: :ignored, scroll_offset: 0}
      assert Top.update(model, {:event, %{key: :arrow_up}}).scroll_offset == 0

      model = %Top{daemon: :ignored, scroll_offset: 3}
      assert Top.update(model, {:event, %{key: :arrow_up}}).scroll_offset == 2
    end

    test "arrow down increments scroll offset" do
      model = %Top{daemon: :ignored, scroll_offset: 5}
      assert Top.update(model, {:event, %{key: :arrow_down}}).scroll_offset == 6
    end

    test "unknown messages return model unchanged" do
      model = %Top{daemon: :ignored, scroll_offset: 7}
      assert Top.update(model, {:event, %{ch: ?x}}).scroll_offset == 7
    end
  end

  describe "render/1" do
    test "renders supervision tree roots without pid" do
      model = %Top{
        daemon: :ignored,
        supervision_tree: [
          %{
            name: "CodexSubagents.Supervisor",
            type: :supervisor,
            children: [
              %{
                name: "CodexSubagents.Registry",
                pid: "#PID<0.97.0>",
                type: :worker,
                children: []
              }
            ]
          }
        ]
      }

      assert {:ok, canvas} = Renderer.render(Canvas.from_dimensions(100, 30), Top.render(model))

      output = Canvas.render_to_string(canvas)
      assert output =~ "CodexSubagents.Supervisor"
      assert output =~ "(not started)"
    end

    test "renders non-empty job rows inside a valid table" do
      now = DateTime.utc_now()

      model = %Top{
        daemon: :ignored,
        total_jobs: 1,
        jobs_by_owner: [
          %{
            owner: "owner-a",
            jobs: [
              %{
                id: "job_abcdefgh",
                status: :succeeded,
                started_at: now,
                finished_at: now,
                label: "hello",
                command: "echo hello"
              }
            ]
          }
        ]
      }

      assert {:ok, canvas} = Renderer.render(Canvas.from_dimensions(100, 30), Top.render(model))

      output = Canvas.render_to_string(canvas)
      assert output =~ "Owner: owner-a"
      assert output =~ "hello"
      assert output =~ "echo hello"
    end
  end
end
