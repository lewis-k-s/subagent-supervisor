defmodule SubagentSupervisor.Agents do
  @moduledoc """
  Discovers and parses Claude Code agent definitions.

  File-backed agents are markdown files with YAML frontmatter found in:
    - User-level:   ~/.claude/agents/*.md
    - Project-level: <cwd>/.claude/agents/*.md

  Claude Code built-in agents are included explicitly, except internal setup
  agents that should not be dispatched directly.
  """

  @built_in_agents [
    %{
      name: "Explore",
      description: "Built-in Claude Code exploration agent",
      source: :builtin,
      path: nil
    },
    %{
      name: "general-purpose",
      description: "Built-in Claude Code general-purpose agent",
      source: :builtin,
      path: nil
    },
    %{
      name: "Plan",
      description: "Built-in Claude Code planning agent",
      source: :builtin,
      path: nil
    }
  ]

  @type agent :: %{
          name: String.t(),
          description: String.t() | nil,
          source: :builtin | :user | :project,
          path: String.t() | nil
        }

  @spec discover(String.t() | nil) :: [agent()]
  def discover(cwd) do
    user_home = System.get_env("HOME") || ""
    discover(cwd, user_home)
  end

  @spec discover(String.t() | nil, String.t()) :: [agent()]
  def discover(cwd, user_home) do
    user_agents =
      if user_home != "" do
        scan_dir(user_agents_dir(user_home), :user)
      else
        []
      end

    project_agents =
      if cwd != nil and cwd != "" do
        scan_dir(project_agents_dir(cwd), :project)
      else
        []
      end

    # Project-level agents shadow user-level and built-in agents with the same name.
    merge_agents(@built_in_agents ++ user_agents, project_agents)
  end

  @spec find(String.t(), String.t() | nil) :: {:ok, agent()} | {:error, :not_found}
  def find(name, cwd) do
    case Enum.find(discover(cwd), &(&1.name == name)) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @spec validate(String.t(), String.t() | nil) ::
          {:ok, agent()} | {:error, {:not_found, String.t()}}
  def validate(name, cwd) do
    case find(name, cwd) do
      {:ok, agent} -> {:ok, agent}
      {:error, :not_found} -> {:error, {:not_found, name}}
    end
  end

  @spec user_agents_dir() :: String.t()
  def user_agents_dir do
    user_home = System.get_env("HOME") || ""
    user_agents_dir(user_home)
  end

  @spec user_agents_dir(String.t()) :: String.t()
  def user_agents_dir(user_home) do
    Path.join(user_home, ".claude/agents")
  end

  @spec project_agents_dir(String.t()) :: String.t()
  def project_agents_dir(cwd) do
    Path.join(cwd, ".claude/agents")
  end

  defp scan_dir(dir, source) do
    pattern = Path.join(dir, "*.md")

    case Path.wildcard(pattern) do
      files when is_list(files) ->
        Enum.flat_map(files, fn path ->
          case parse_agent_file(path, source) do
            {:ok, agent} -> [agent]
            :error -> []
          end
        end)

      _ ->
        []
    end
  end

  defp parse_agent_file(path, source) do
    case File.read(path) do
      {:ok, content} ->
        frontmatter = parse_frontmatter(content)
        name = resolve_name(frontmatter, path)

        if name == nil or name == "" do
          :error
        else
          {:ok,
           %{
             name: name,
             description: Map.get(frontmatter, "description"),
             source: source,
             path: path
           }}
        end

      {:error, _} ->
        :error
    end
  end

  defp parse_frontmatter(content) do
    case String.split(content, "---", parts: 3) do
      ["", frontmatter, _body] ->
        frontmatter
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ":", parts: 2) do
            [key, value] ->
              Map.put(acc, String.trim(key), String.trim(value))

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp resolve_name(frontmatter, path) do
    case Map.get(frontmatter, "name") do
      nil -> path |> Path.basename(".md")
      "" -> path |> Path.basename(".md")
      name -> name
    end
  end

  defp merge_agents(user_agents, project_agents) do
    project_names = MapSet.new(project_agents, & &1.name)

    kept_user =
      Enum.reject(user_agents, fn agent ->
        MapSet.member?(project_names, agent.name)
      end)

    project_agents ++ kept_user
  end
end
