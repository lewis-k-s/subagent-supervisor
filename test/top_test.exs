defmodule CodexSubagents.TopTest do
  use ExUnit.Case

  import Ratatouille.Constants, only: [key: 1]

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
      assert model.window_height == 44
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

  describe "update/2 - dashboard navigation" do
    test "arrow up decrements selected_index with floor at 0" do
      model = %Top{daemon: :ignored, view_mode: :dashboard, selected_index: 0, total_jobs: 3}
      assert Top.update(model, {:event, %{key: key(:arrow_up)}}).selected_index == 0

      model = %Top{daemon: :ignored, view_mode: :dashboard, selected_index: 3, total_jobs: 5}
      assert Top.update(model, {:event, %{key: key(:arrow_up)}}).selected_index == 2
    end

    test "arrow down increments selected_index capped at total - 1" do
      model = %Top{daemon: :ignored, view_mode: :dashboard, selected_index: 2, total_jobs: 5}
      assert Top.update(model, {:event, %{key: key(:arrow_down)}}).selected_index == 3

      model = %Top{daemon: :ignored, view_mode: :dashboard, selected_index: 4, total_jobs: 5}
      assert Top.update(model, {:event, %{key: key(:arrow_down)}}).selected_index == 4
    end

    test "q halts in dashboard mode" do
      model = %Top{daemon: :ignored, view_mode: :dashboard}
      assert catch_exit(Top.update(model, {:event, %{ch: ?q}}))
    end
  end

  describe "update/2 - output mode" do
    test "escape returns to dashboard" do
      model = %Top{
        daemon: :ignored,
        view_mode: :output,
        selected_job_id: "job_123",
        selected_job_output: "some output",
        output_scroll: 5
      }

      updated = Top.update(model, {:event, %{key: key(:esc)}})
      assert updated.view_mode == :dashboard
      assert updated.selected_job_id == nil
      assert updated.selected_job_output == ""
      assert updated.output_scroll == 0
    end

    test "arrow up decrements output_scroll with floor at 0 and disables auto-scroll" do
      model = %Top{
        daemon: :ignored,
        view_mode: :output,
        output_scroll: 0,
        output_auto_scroll: true
      }

      updated = Top.update(model, {:event, %{key: key(:arrow_up)}})
      assert updated.output_scroll == 0
      assert updated.output_auto_scroll == false

      model = %Top{
        daemon: :ignored,
        view_mode: :output,
        output_scroll: 5,
        output_auto_scroll: true
      }

      updated = Top.update(model, {:event, %{key: key(:arrow_up)}})
      assert updated.output_scroll == 4
      assert updated.output_auto_scroll == false
    end

    test "arrow down increments output_scroll and disables auto-scroll" do
      model = %Top{
        daemon: :ignored,
        view_mode: :output,
        output_scroll: 3,
        output_auto_scroll: true
      }

      updated = Top.update(model, {:event, %{key: key(:arrow_down)}})
      assert updated.output_scroll == 4
      assert updated.output_auto_scroll == false
    end

    test "q does not halt in output mode" do
      model = %Top{daemon: :ignored, view_mode: :output}
      updated = Top.update(model, {:event, %{ch: ?q}})
      assert updated.view_mode == :output
    end
  end

  describe "update/2 - enter to view output" do
    test "enter switches to output mode when jobs exist" do
      job = %{
        id: "job_abc123",
        status: :succeeded,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        label: "test",
        command: "echo hi",
        inserted_at: DateTime.utc_now()
      }

      model = %Top{
        daemon: :ignored,
        view_mode: :dashboard,
        selected_index: 0,
        total_jobs: 1,
        all_jobs: [job]
      }

      updated = Top.update(model, {:event, %{key: key(:enter)}})
      assert updated.view_mode == :output
      assert updated.selected_job_id == "job_abc123"
    end

    test "enter does nothing when no jobs" do
      model = %Top{daemon: :ignored, view_mode: :dashboard, total_jobs: 0, all_jobs: []}
      updated = Top.update(model, {:event, %{key: key(:enter)}})
      assert updated.view_mode == :dashboard
    end
  end

  describe "render/1 - dashboard" do
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
        all_jobs: [
          %{
            id: "job_abcdefgh",
            status: :succeeded,
            started_at: now,
            finished_at: now,
            label: "hello",
            command: "echo hello",
            inserted_at: now
          }
        ],
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
                command: "echo hello",
                inserted_at: now
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

    test "renders selected job with blue background" do
      now = DateTime.utc_now()

      model = %Top{
        daemon: :ignored,
        total_jobs: 1,
        selected_index: 0,
        all_jobs: [
          %{
            id: "job_abcdefgh",
            status: :succeeded,
            started_at: now,
            finished_at: now,
            label: "hello",
            command: "echo hello",
            inserted_at: now
          }
        ],
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
                command: "echo hello",
                inserted_at: now
              }
            ]
          }
        ]
      }

      assert {:ok, canvas} = Renderer.render(Canvas.from_dimensions(100, 30), Top.render(model))
      output = Canvas.render_to_string(canvas)
      assert output =~ "Owner: owner-a"
    end
  end

  describe "render/1 - output mode" do
    test "renders output view with panel title" do
      now = DateTime.utc_now()

      model = %Top{
        daemon: :ignored,
        view_mode: :output,
        selected_job_id: "job_abc123",
        selected_job_output: "line1\nline2\nline3",
        all_jobs: [
          %{
            id: "job_abc123",
            status: :succeeded,
            started_at: now,
            finished_at: now,
            label: "test-job",
            command: "echo hi",
            inserted_at: now
          }
        ]
      }

      assert {:ok, canvas} = Renderer.render(Canvas.from_dimensions(100, 30), Top.render(model))
      output = Canvas.render_to_string(canvas)
      assert output =~ "Output: job_abc1"
      assert output =~ "test-job"
      assert output =~ "line1"
      assert output =~ "line2"
      assert output =~ "line3"
    end

    test "renders no output yet message when empty" do
      now = DateTime.utc_now()

      model = %Top{
        daemon: :ignored,
        view_mode: :output,
        selected_job_id: "job_abc123",
        selected_job_output: "",
        all_jobs: [
          %{
            id: "job_abc123",
            status: :running,
            started_at: now,
            finished_at: nil,
            label: nil,
            command: "echo hi",
            inserted_at: now
          }
        ]
      }

      assert {:ok, canvas} = Renderer.render(Canvas.from_dimensions(100, 30), Top.render(model))
      output = Canvas.render_to_string(canvas)
      assert output =~ "no output yet"
    end
  end
end
