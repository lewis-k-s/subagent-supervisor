defmodule SubagentSupervisor.Registry do
  @moduledoc """
  Owns job state and supervises bash subprocess tasks.
  """

  use GenServer

  alias SubagentSupervisor.Job
  alias SubagentSupervisor.Registry.Persistence
  alias SubagentSupervisor.StreamJSON
  require Logger

  @type wait_mode :: :any | :all
  @write_capable_agents ["sweng-coder"]
  @jobs_table Module.concat(__MODULE__, Jobs)

  @doc """
  Starts the Registry GenServer as a named process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers and runs a bash subprocess job.

  Required attributes: `"owner"`, `"command"`.
  Optional attributes: `"cwd"`, `"label"`, `"id"`.

  Returns `{:ok, job_map}` on success or raises `ArgumentError` if required
  attributes are missing.
  """
  @spec start_job(map()) :: {:ok, map()} | {:error, String.t()}
  def start_job(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:start_job, attrs})
  end

  @doc """
  Lists jobs, optionally filtered by owner.

  Pass `nil` (the default) to return all jobs.
  """
  @spec list(String.t() | nil) :: {:ok, [map()]}
  def list(owner \\ nil) do
    GenServer.call(__MODULE__, {:list, owner})
  end

  @doc """
  Returns the details of a single job.

  By default, output is omitted. Pass `include_output: true` to include
  the full captured output, or `include_output: :digest` to include a
  truncated digest.

  Returns `{:error, :not_found}` when the id does not exist.
  """
  @spec show(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def show(id, opts \\ []) do
    GenServer.call(__MODULE__, {:show, id, opts})
  end

  @doc """
  Returns a lightweight status digest for a job: metadata plus a
  truncated view of the output.

  Returns `{:error, :not_found}` when the id does not exist.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(id) do
    GenServer.call(__MODULE__, {:status, id})
  end

  @doc """
  Returns dashboard state: jobs grouped by owner, concurrency stats,
  supervision tree children, and daemon start time.
  """
  @spec dashboard_state() :: {:ok, map()}
  def dashboard_state do
    GenServer.call(__MODULE__, :dashboard_state)
  end

  @doc """
  Resets all job state. Intended for use in tests.
  """
  @spec reset_for_test(pos_integer()) :: :ok
  def reset_for_test(max_concurrency \\ max_concurrency()) do
    GenServer.call(__MODULE__, {:reset_for_test, max_concurrency})
  end

  @doc """
  Reads the current output for a job from its temp file.

  Returns `{:ok, content}` with partial or full output, or
  `{:error, :not_found}` / `{:error, :no_output}`.
  """
  @spec read_output(String.t()) :: {:ok, String.t()} | {:error, :not_found | :no_output}
  def read_output(id) do
    GenServer.call(__MODULE__, {:read_output, id})
  end

  @doc """
  Registers an external Claude session as a synthetic job.

  Creates a job with `:registered` status representing a session managed
  outside the supervisor. Required attributes: `"owner"`, `"session_id"`.
  Optional attributes: `"label"`, `"cwd"`.

  Returns `{:ok, job_map}` on success.
  """
  @spec register(map()) :: {:ok, map()} | no_return()
  def register(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:register, attrs})
  end

  @doc """
  Reads the stream-json capture for a job, formatting it according to `mode`.

  Modes:
    * `:parsed`  — text deltas + tool labels (default, concise)
    * `:verbose` — assembled snapshots with thinking, tool I/O, cost metadata

  Returns `{:ok, text}`, `{:error, :not_found}`, or `{:error, :no_output}`.
  """
  @spec read_stream_output(String.t(), :parsed | :verbose) ::
          {:ok, String.t()} | {:error, :not_found | :no_output}
  def read_stream_output(id, mode \\ :parsed) do
    GenServer.call(__MODULE__, {:read_stream_output, id, mode})
  end

  @doc """
  Blocks until the selected wake rule is satisfied.

  * `:any` — returns when at least one matching job finishes.
  * `:all` — returns when every matching job finishes.

  Times out after `timeout_ms` milliseconds, returning `{:error, :timeout}`.
  """
  @spec wait(String.t() | nil, [String.t()], wait_mode(), pos_integer()) ::
          {:ok, [map()]} | {:error, :timeout}
  def wait(owner, ids, mode, timeout_ms) when mode in [:any, :all] do
    GenServer.call(__MODULE__, {:wait, owner, ids, mode, timeout_ms}, timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @impl true
  def init(opts) do
    state_dir = Persistence.state_dir(opts)
    File.mkdir_p!(Persistence.log_dir(state_dir))
    ets_table = ensure_ets_table!()
    server_sandbox = detect_server_sandbox()
    now = DateTime.utc_now()

    {:ok, loaded_jobs} = Persistence.load(state_dir)
    {loaded_jobs, recovered?} = recover_jobs(loaded_jobs, now)
    jobs = Map.new(loaded_jobs, &{&1.id, &1})

    if recovered? do
      Persistence.save!(state_dir, jobs)
    end

    hydrate_ets!(ets_table, jobs)

    state = %{
      jobs: jobs,
      queue: rebuild_queue(jobs),
      refs: %{},
      waiters: [],
      ets_table: ets_table,
      max_concurrency: Keyword.get(opts, :max_concurrency, max_concurrency()) |> max(1),
      started_at: now,
      state_dir: state_dir,
      allowed_launchers: resolve_allowed_launchers(),
      server_sandbox: server_sandbox
    }

    {:ok, start_available_jobs(state)}
  end

  @impl true
  def handle_call({:start_job, attrs}, _from, state) do
    case build_job(attrs, state) do
      {:ok, job} ->
        state = state |> enqueue_job(job) |> start_available_jobs()
        {:reply, {:ok, public_job(Map.fetch!(state.jobs, job.id))}, state}

      {:error, reason} ->
        log_failed_launch(attrs, reason)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list, owner}, _from, state) do
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(is_nil(owner) or &1.owner == owner))
      |> sort_jobs()
      |> Enum.map(&public_job/1)

    {:reply, {:ok, jobs}, state}
  end

  def handle_call({:show, id, opts}, _from, state) do
    reply =
      case Map.fetch(state.jobs, id) do
        {:ok, job} ->
          include_output =
            case Keyword.get(opts, :include_output) do
              true -> true
              :digest -> :digest
              _ -> false
            end

          {:ok, public_job(job, include_output: include_output)}

        :error ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:status, id}, _from, state) do
    reply =
      case Map.fetch(state.jobs, id) do
        {:ok, job} -> {:ok, build_status(job, state)}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:reset_for_test, max_concurrency}, _from, state) do
    Enum.each(state.waiters, fn waiter ->
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, {:error, :reset})
    end)

    Persistence.clear!(state.state_dir)
    :ets.delete_all_objects(state.ets_table)

    {:reply, :ok,
     %{
       state
       | jobs: %{},
         queue: :queue.new(),
         refs: %{},
         waiters: [],
         max_concurrency: max(max_concurrency, 1)
     }}
  end

  def handle_call(:dashboard_state, _from, state) do
    jobs = state.jobs |> Map.values() |> Enum.map(&public_job/1)

    grouped =
      jobs
      |> Enum.group_by(& &1.owner)
      |> Enum.map(fn {owner, owner_jobs} -> %{owner: owner, jobs: owner_jobs} end)
      |> Enum.sort_by(& &1.owner)

    running = Enum.count(jobs, &(&1.status == :running))
    queued = Enum.count(jobs, &(&1.status == :queued))

    {:ok, sup_children} =
      case Supervisor.which_children(SubagentSupervisor.Supervisor) do
        children -> {:ok, format_sup_children(children)}
      end

    result = %{
      jobs_by_owner: grouped,
      total_jobs: length(jobs),
      running: running,
      queued: queued,
      max_concurrency: state.max_concurrency,
      started_at: state.started_at,
      server_sandbox: state.server_sandbox,
      supervision_tree: [
        %{
          name: "SubagentSupervisor.Supervisor",
          type: :supervisor,
          children: sup_children
        }
      ]
    }

    {:reply, {:ok, result}, state}
  end

  def handle_call({:wait, owner, ids, mode, timeout_ms}, from, state) do
    selector = normalize_selector(owner, ids)

    case wait_result(state.jobs, selector, mode) do
      {:ready, jobs} ->
        {:reply, {:ok, Enum.map(jobs, &public_job(&1, include_output: true))}, state}

      :pending ->
        ref = make_ref()
        timer = Process.send_after(self(), {:wait_timeout, ref}, timeout_ms)
        waiter = %{ref: ref, timer: timer, from: from, selector: selector, mode: mode}
        {:noreply, %{state | waiters: [waiter | state.waiters]}}
    end
  end

  def handle_call({:read_output, id}, _from, state) do
    reply =
      case Map.fetch(state.jobs, id) do
        {:ok, %Job{output_path: nil}} ->
          {:error, :no_output}

        {:ok, %Job{output_path: path}} ->
          if File.exists?(path) do
            {:ok, File.read!(path)}
          else
            {:error, :no_output}
          end

        :error ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:read_stream_output, id, mode}, _from, state) do
    reply =
      case Map.fetch(state.jobs, id) do
        {:ok, %Job{output_path: nil}} ->
          {:error, :no_output}

        {:ok, %Job{output_path: path}} ->
          if File.exists?(path) do
            raw = File.read!(path)

            text =
              case mode do
                :verbose -> StreamJSON.extract_verbose(raw)
                _ -> raw |> StreamJSON.format_incremental(0) |> elem(0) |> tagged_text()
              end

            {:ok, text}
          else
            {:error, :no_output}
          end

        :error ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:register, attrs}, _from, state) do
    owner = required!(attrs, "owner")
    session_id = Map.get(attrs, "session_id")
    cwd = normalize_existing_dir!(Map.get(attrs, "cwd", File.cwd!()))
    label = Map.get(attrs, "label")
    id = Map.get(attrs, "id", new_id())
    inserted_at = now()

    job = %Job{
      id: id,
      owner: owner,
      command: nil,
      cwd: cwd,
      label: label,
      agent: nil,
      sandbox_write_roots: [],
      sandbox_write_bounded: false,
      cwd_writable: true,
      server_sandbox: state.server_sandbox,
      session_id: session_id,
      status: :registered,
      inserted_at: inserted_at,
      started_at: nil
    }

    state = commit_job(state, job)
    {:reply, {:ok, public_job(Map.fetch!(state.jobs, id))}, state}
  end

  @impl true
  def handle_info({ref, {id, started_at, finished_at, exit_status}}, state) do
    Process.demonitor(ref, [:flush])

    state =
      update_job(state, id, fn job ->
        raw =
          if job.output_path && File.exists?(job.output_path) do
            File.read!(job.output_path)
          else
            ""
          end

        output = StreamJSON.extract_text(raw)
        session_id = StreamJSON.extract_session_id(raw)

        %{
          job
          | status: terminal_status(exit_status),
            exit_status: exit_status,
            output: output,
            session_id: session_id,
            started_at: started_at,
            finished_at: finished_at,
            task_ref: nil
        }
      end)

    state = state |> start_available_jobs() |> reply_ready_waiters()
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    id = Map.get(state.refs, ref)

    state =
      if id do
        update_job(state, id, fn job ->
          raw =
            if job.output_path && File.exists?(job.output_path) do
              File.read!(job.output_path)
            else
              ""
            end

          parsed = StreamJSON.extract_text(raw)
          partial = if raw != parsed, do: "\n" <> parsed, else: parsed

          %{
            job
            | status: :failed,
              exit_status: nil,
              output: "Task process exited before returning: #{inspect(reason)}" <> partial,
              finished_at: now(),
              task_ref: nil
          }
        end)
      else
        state
      end

    state = state |> start_available_jobs() |> reply_ready_waiters()
    {:noreply, state}
  end

  def handle_info({:wait_timeout, ref}, state) do
    {expired, pending} = Enum.split_with(state.waiters, &(&1.ref == ref))

    Enum.each(expired, fn waiter ->
      GenServer.reply(waiter.from, {:error, :timeout})
    end)

    {:noreply, %{state | waiters: pending}}
  end

  defp enqueue_job(state, job) do
    state = commit_job(state, job)
    %{state | queue: :queue.in(job.id, state.queue)}
  end

  defp commit_job(state, %Job{} = job) do
    jobs = Map.put(state.jobs, job.id, job)

    Persistence.save!(state.state_dir, jobs)
    :ets.insert(state.ets_table, {job.id, Job.to_persisted_map(job)})

    old_job = Map.get(state.jobs, job.id)
    refs = update_refs(state.refs, old_job, job)

    %{state | jobs: jobs, refs: refs}
  end

  defp attach_task_ref(state, id, ref) do
    case Map.fetch(state.jobs, id) do
      {:ok, job} ->
        job = %{job | task_ref: ref}
        jobs = Map.put(state.jobs, id, job)
        refs = Map.put(state.refs, ref, id)
        %{state | jobs: jobs, refs: refs}

      :error ->
        state
    end
  end

  defp update_refs(refs, old_job, new_job) do
    refs =
      case old_job do
        %Job{task_ref: ref} when not is_nil(ref) -> Map.delete(refs, ref)
        _ -> refs
      end

    case new_job do
      %Job{task_ref: ref} when not is_nil(ref) -> Map.put(refs, ref, new_job.id)
      _ -> refs
    end
  end

  defp ensure_ets_table! do
    case :ets.whereis(@jobs_table) do
      :undefined ->
        :ets.new(@jobs_table, [:named_table, :protected, :set, read_concurrency: true])

      table ->
        :ets.delete_all_objects(table)
        table
    end
  end

  defp hydrate_ets!(table, jobs) do
    :ets.delete_all_objects(table)

    jobs
    |> Map.values()
    |> Enum.each(fn job -> :ets.insert(table, {job.id, Job.to_persisted_map(job)}) end)
  end

  defp recover_jobs(jobs, now) do
    Enum.map_reduce(jobs, false, fn job, recovered? ->
      recovered_job = recover_job(job, now)
      {recovered_job, recovered? or recovered_job != job}
    end)
  end

  defp recover_job(%Job{status: :running} = job, now) do
    %{
      job
      | status: :failed,
        exit_status: nil,
        finished_at: now,
        task_ref: nil,
        output: append_interruption(job.output)
    }
  end

  defp recover_job(%Job{} = job, _now), do: %{job | task_ref: nil}

  defp append_interruption(nil), do: interruption_message()
  defp append_interruption(""), do: interruption_message()
  defp append_interruption(output), do: output <> "\n" <> interruption_message()

  defp interruption_message do
    "Task interrupted: daemon restarted before the process completed."
  end

  defp rebuild_queue(jobs) do
    jobs
    |> Map.values()
    |> Enum.filter(&(&1.status == :queued))
    |> sort_jobs()
    |> Enum.reduce(:queue.new(), fn job, queue -> :queue.in(job.id, queue) end)
  end

  defp start_available_jobs(state) do
    available = state.max_concurrency - running_count(state)

    dispatch_queued_jobs(state, available)
  end

  defp dispatch_queued_jobs(state, available) when available <= 0, do: state

  defp dispatch_queued_jobs(state, available) do
    case :queue.out(state.queue) do
      {{:value, id}, queue} ->
        state = %{state | queue: queue}

        case Map.fetch(state.jobs, id) do
          {:ok, %Job{status: :queued} = job} ->
            state
            |> start_job_task(job)
            |> dispatch_queued_jobs(available - 1)

          _ ->
            dispatch_queued_jobs(state, available)
        end

      {:empty, _queue} ->
        state
    end
  end

  defp start_job_task(state, job) do
    started_at = now()
    output_path = Persistence.log_path(state.state_dir, job.id)
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, "")
    command = job.command
    running_job = %{job | status: :running, started_at: started_at, output_path: output_path}
    state = commit_job(state, running_job)

    task =
      Task.Supervisor.async_nolink(SubagentSupervisor.TaskSupervisor, fn ->
        port =
          Port.open(
            {:spawn_executable, System.find_executable("bash")},
            [
              :binary,
              :use_stdio,
              :exit_status,
              {:args, ["-lc", "(#{command}) < /dev/null 2>&1"]},
              {:cd, String.to_charlist(job.cwd)},
              {:env, job_env(job)}
            ]
          )

        exit_status = collect_port_output(port, output_path)
        {job.id, started_at, now(), exit_status}
      end)

    attach_task_ref(state, running_job.id, task.ref)
  end

  defp collect_port_output(port, path) do
    receive do
      {^port, {:data, data}} ->
        File.write!(path, data, [:append])
        collect_port_output(port, path)

      {^port, {:exit_status, code}} ->
        receive do
          {^port, :closed} -> :ok
        after
          100 -> :ok
        end

        code
    end
  end

  defp job_env(job) do
    roots = Enum.join(job.sandbox_write_roots || [], ":")

    [
      {~c"SUBAGENT_SUPERVISOR_CWD", String.to_charlist(job.cwd)},
      {~c"SUBAGENT_SUPERVISOR_CWD_WRITABLE", if(job.cwd_writable, do: ~c"1", else: ~c"0")},
      {~c"SUBAGENT_SUPERVISOR_SANDBOX_WRITE_BOUNDED",
       if(job.sandbox_write_bounded, do: ~c"1", else: ~c"0")},
      {~c"SUBAGENT_SUPERVISOR_SANDBOX_WRITE_ROOTS", String.to_charlist(roots)},
      {~c"SUBAGENT_SUPERVISOR_SERVER_SANDBOX_INHERITED",
       if(job.server_sandbox.inherited, do: ~c"1", else: ~c"0")},
      {~c"SUBAGENT_SUPERVISOR_SERVER_SANDBOX_KIND",
       String.to_charlist(to_string(job.server_sandbox.kind))}
    ]
  end

  defp running_count(state) do
    state.jobs
    |> Map.values()
    |> Enum.count(&(&1.status == :running))
  end

  defp update_job(state, id, fun) do
    case Map.fetch(state.jobs, id) do
      {:ok, job} ->
        updated = fun.(job)
        commit_job(state, updated)

      :error ->
        state
    end
  end

  defp reply_ready_waiters(state) do
    {ready, pending} =
      Enum.split_with(state.waiters, fn waiter ->
        match?({:ready, _jobs}, wait_result(state.jobs, waiter.selector, waiter.mode))
      end)

    Enum.each(ready, fn waiter ->
      {:ready, jobs} = wait_result(state.jobs, waiter.selector, waiter.mode)
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, {:ok, Enum.map(jobs, &public_job(&1, include_output: true))})
    end)

    %{state | waiters: pending}
  end

  defp wait_result(jobs, selector, :any) do
    candidates = select_jobs(jobs, selector)

    case Enum.find(candidates, &terminal?/1) do
      nil -> :pending
      job -> {:ready, [job]}
    end
  end

  defp wait_result(jobs, selector, :all) do
    candidates = select_jobs(jobs, selector)

    cond do
      candidates == [] -> :pending
      Enum.all?(candidates, &terminal?/1) -> {:ready, candidates}
      true -> :pending
    end
  end

  defp select_jobs(jobs, %{owner: owner, ids: []}) do
    jobs
    |> Map.values()
    |> Enum.filter(&(&1.owner == owner))
    |> sort_jobs()
  end

  defp select_jobs(jobs, %{ids: ids}) do
    ids
    |> Enum.map(&Map.get(jobs, &1))
    |> Enum.reject(&is_nil/1)
    |> sort_jobs()
  end

  defp normalize_selector(owner, ids), do: %{owner: owner, ids: ids || []}
  defp terminal?(%Job{status: status}), do: status in [:succeeded, :failed, :registered]
  defp terminal_status(0), do: :succeeded
  defp terminal_status(_), do: :failed
  defp sort_jobs(jobs), do: Enum.sort_by(jobs, &DateTime.to_unix(&1.inserted_at, :microsecond))

  defp public_job(job, opts \\ []) do
    base = %{
      id: job.id,
      owner: job.owner,
      label: job.label,
      agent: job.agent,
      command: job.command,
      cwd: job.cwd,
      cwd_writable: job.cwd_writable,
      sandbox_write_roots: job.sandbox_write_roots,
      sandbox_write_bounded: job.sandbox_write_bounded,
      server_sandbox: job.server_sandbox,
      session_id: job.session_id,
      accepted: true,
      observable: true,
      status: job.status,
      exit_status: job.exit_status,
      inserted_at: job.inserted_at,
      started_at: job.started_at,
      finished_at: job.finished_at
    }

    case Keyword.get(opts, :include_output, false) do
      true -> Map.put(base, :output, public_output(job))
      :digest -> Map.put(base, :output, job.output)
      _ -> base
    end
  end

  defp public_output(job) do
    case read_job_output(job) do
      "" -> job.output || ""
      nil -> job.output
      raw -> StreamJSON.extract_text(raw)
    end
  end

  defp build_status(job, _state) do
    raw_output = read_job_output(job)

    output_digest =
      case raw_output do
        nil ->
          nil

        "" ->
          job.output || ""

        raw ->
          text = StreamJSON.extract_text(raw)
          truncate_text(text)
      end

    %{
      id: job.id,
      label: job.label,
      status: job.status,
      owner: job.owner,
      session_id: job.session_id,
      started_at: job.started_at,
      finished_at: job.finished_at,
      output_digest: output_digest
    }
  end

  defp read_job_output(%Job{output_path: nil}), do: nil

  defp read_job_output(%Job{output_path: path}) do
    if File.exists?(path), do: File.read!(path), else: nil
  end

  @max_digest 4000
  @head_chars 500
  @tail_chars 3000

  defp truncate_text(text) when byte_size(text) <= @max_digest, do: text

  defp truncate_text(text) do
    head = String.slice(text, 0, @head_chars)
    tail = String.slice(text, String.length(text) - @tail_chars, @tail_chars)
    head <> "\n\n... [truncated] ...\n\n" <> tail
  end

  defp tagged_text(chunks) do
    chunks
    |> Enum.map(fn {text, _color} -> text end)
    |> Enum.join()
  end

  defp required!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when value not in [nil, ""] -> value
      _ -> raise ArgumentError, "missing required #{key}"
    end
  end

  defp new_id do
    "job_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end

  defp now, do: DateTime.utc_now()

  defp max_concurrency do
    :subagent_supervisor
    |> Application.get_env(:max_concurrency, 2)
    |> max(1)
  end

  defp format_sup_children(children) do
    Enum.map(children, fn {id, pid, type, _modules} ->
      %{
        name: inspect(id),
        type: type,
        pid: format_pid(pid),
        children: child_grandchildren(id, pid)
      }
    end)
  end

  defp child_grandchildren(:subagent_supervisor_task_supervisor, pid) when is_pid(pid) do
    case Task.Supervisor.children(pid) do
      pids ->
        Enum.map(
          pids,
          &%{name: "Task #{format_pid(&1)}", type: :worker, pid: format_pid(&1), children: []}
        )
    end
  end

  defp child_grandchildren(_id, _pid), do: []

  defp format_pid(nil), do: "not started"
  defp format_pid(:restarting), do: "restarting"
  defp format_pid(pid) when is_pid(pid), do: inspect(pid)

  defp resolve_allowed_launchers do
    SubagentSupervisor.Launcher.allowed_launchers()
  end

  defp build_job(attrs, state) do
    with {:ok, owner} <- required(attrs, "owner"),
         {:ok, command} <- required(attrs, "command"),
         :ok <- validate_command(command, state.allowed_launchers),
         {:ok, cwd} <- normalize_existing_dir(Map.get(attrs, "cwd", File.cwd!())) do
      label = Map.get(attrs, "label")
      agent = Map.get(attrs, "agent")
      client_write_roots = normalize_write_roots(Map.get(attrs, "sandbox_write_roots", []))
      sandbox_write_roots = effective_write_roots(client_write_roots, state.server_sandbox)
      sandbox_write_bounded = write_roots_bounded?(client_write_roots, state.server_sandbox)
      cwd_writable = cwd_writable?(cwd, sandbox_write_roots, sandbox_write_bounded)
      id = Map.get(attrs, "id", new_id())
      inserted_at = now()

      with :ok <- validate_agent_write_policy(agent, cwd, cwd_writable, sandbox_write_roots),
           :ok <- validate_agent(agent, cwd) do
        {:ok,
         %Job{
           id: id,
           owner: owner,
           command: command,
           cwd: cwd,
           label: label,
           agent: agent,
           sandbox_write_roots: sandbox_write_roots,
           sandbox_write_bounded: sandbox_write_bounded,
           cwd_writable: cwd_writable,
           server_sandbox: state.server_sandbox,
           session_id: Map.get(attrs, "session_id"),
           status: :queued,
           inserted_at: inserted_at,
           started_at: nil
         }}
      end
    end
  end

  defp log_failed_launch(attrs, reason) do
    Logger.info(fn ->
      owner = Map.get(attrs, "owner") || Map.get(attrs, "session")
      label = Map.get(attrs, "label")
      agent = Map.get(attrs, "agent")
      cwd = Map.get(attrs, "cwd")

      "subagent launch rejected owner=#{inspect(owner)} label=#{inspect(label)} agent=#{inspect(agent)} cwd=#{inspect(cwd)} reason=#{reason}"
    end)
  end

  defp detect_server_sandbox do
    inherited =
      codex_sandbox_env?() or System.get_env("SUBAGENT_SUPERVISOR_INHERITED_SANDBOX") == "1"

    roots = configured_sandbox_write_roots()

    roots =
      cond do
        roots != [] ->
          roots

        inherited ->
          [File.cwd!(), System.tmp_dir!()] |> normalize_write_roots()

        true ->
          []
      end

    %{
      inherited: inherited,
      kind: if(inherited, do: :codex, else: :none),
      write_roots: roots,
      source: sandbox_source(inherited, roots)
    }
  end

  defp configured_sandbox_write_roots do
    configured =
      System.get_env("SUBAGENT_SUPERVISOR_SERVER_SANDBOX_WRITE_ROOTS") ||
        System.get_env("SUBAGENT_SUPERVISOR_SANDBOX_WRITE_ROOTS") ||
        System.get_env("SUBAGENT_SUPERVISOR_SANDBOX_WRITABLE_ROOTS")

    normalize_write_roots(configured || [])
  end

  defp codex_sandbox_env? do
    System.get_env("CODEX_SANDBOX") == "seatbelt" or System.get_env("CODEX_SHELL") == "1"
  end

  defp sandbox_source(false, []), do: :none
  defp sandbox_source(true, []), do: :codex_env
  defp sandbox_source(_, _roots), do: :env_roots

  defp effective_write_roots(client_roots, %{inherited: true, write_roots: server_roots})
       when client_roots != [] and server_roots != [] do
    intersect_roots(client_roots, server_roots)
  end

  defp effective_write_roots(_client_roots, %{inherited: true, write_roots: server_roots})
       when server_roots != [] do
    server_roots
  end

  defp effective_write_roots(client_roots, _server_sandbox), do: client_roots

  defp intersect_roots(left, right) do
    for a <- left,
        b <- right,
        root = narrower_root(a, b),
        root != nil,
        uniq: true do
      root
    end
  end

  defp narrower_root(a, b) do
    cond do
      path_inside?(a, b) -> a
      path_inside?(b, a) -> b
      true -> nil
    end
  end

  defp normalize_write_roots(roots) when is_list(roots) do
    roots
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&normalize_path/1)
  end

  defp normalize_write_roots(roots) when is_binary(roots) do
    roots
    |> String.split([":", "\n"], trim: true)
    |> normalize_write_roots()
  end

  defp normalize_write_roots(_), do: []

  defp write_roots_bounded?(_client_roots, %{inherited: true}), do: true
  defp write_roots_bounded?(client_roots, _server_sandbox), do: client_roots != []

  defp cwd_writable?(_cwd, [], false), do: true
  defp cwd_writable?(_cwd, [], true), do: false

  defp cwd_writable?(cwd, roots, _bounded) do
    Enum.any?(roots, &path_inside?(cwd, &1))
  end

  defp path_inside?(path, root) do
    path = normalize_path(path)
    root = normalize_path(root)

    path == root or String.starts_with?(path, root <> "/")
  end

  defp normalize_path(path) do
    path
    |> to_string()
    |> Path.expand()
  end

  defp normalize_existing_dir(path) do
    path = normalize_path(path)

    if File.dir?(path) do
      {:ok, path}
    else
      {:error, "cwd must be an existing directory: #{path}"}
    end
  end

  defp normalize_existing_dir!(path) do
    case normalize_existing_dir(path) do
      {:ok, path} -> path
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp validate_agent_write_policy(nil, _cwd, _cwd_writable, _roots), do: :ok

  defp validate_agent_write_policy(agent, cwd, false, roots)
       when agent in @write_capable_agents do
    {:error,
     "agent #{agent} requires write access, but cwd #{cwd} is outside sandbox write roots #{inspect(roots)}"}
  end

  defp validate_agent_write_policy(_agent, _cwd, _cwd_writable, _roots), do: :ok

  defp validate_command(command, allowed_launchers) do
    if Enum.any?(allowed_launchers, fn launcher ->
         command == launcher or
           String.starts_with?(command, launcher <> " ") or
           command == shell_quote_launcher(launcher) or
           String.starts_with?(command, shell_quote_launcher(launcher) <> " ")
       end) do
      :ok
    else
      {:error,
       "command rejected: must use an allowed launcher (#{inspect(allowed_launchers)}), got: #{command}"}
    end
  end

  defp shell_quote_launcher(launcher) do
    if String.match?(launcher, ~r/^[A-Za-z0-9_\/.,:=@%+-]+$/) do
      launcher
    else
      "'" <> String.replace(launcher, "'", "'\"'\"'") <> "'"
    end
  end

  defp validate_agent(nil, _cwd), do: :ok

  defp validate_agent(agent_name, cwd) do
    case SubagentSupervisor.Agents.validate(agent_name, cwd) do
      {:ok, _} ->
        :ok

      {:error, {:not_found, name}} ->
        available =
          SubagentSupervisor.Agents.discover(cwd)
          |> Enum.map(& &1.name)
          |> Enum.sort()
          |> Enum.join(", ")

        {:error,
         "unknown agent: #{name}" <>
           if(available != "", do: " (available: #{available})", else: "")}
    end
  end

  defp required(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when value not in [nil, ""] -> {:ok, value}
      _ -> {:error, "missing required #{key}"}
    end
  end
end
