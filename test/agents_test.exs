defmodule SubagentSupervisor.AgentsTest do
  use ExUnit.Case

  describe "discover/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "agents-test-#{System.unique_integer([:positive])}")
      user_home = Path.join(tmp, "home")
      project = Path.join(tmp, "project")

      File.mkdir_p!(Path.join(user_home, ".claude/agents"))
      File.mkdir_p!(Path.join(project, ".claude/agents"))

      on_exit(fn -> File.rm_rf!(tmp) end)

      %{tmp: tmp, user_home: user_home, project: project}
    end

    test "discovers user-level agents", %{user_home: home} do
      write_agent(Path.join([home, ".claude", "agents", "my-agent.md"]), %{
        "name" => "my-agent",
        "description" => "Test agent"
      })

      agents = SubagentSupervisor.Agents.discover("/nonexistent", home)

      agent = Enum.find(agents, &(&1.name == "my-agent"))
      assert agent.name == "my-agent"
      assert agent.source == :user
    end

    test "discovers project-level agents", %{user_home: home, project: project} do
      write_agent(Path.join([project, ".claude", "agents", "proj-agent.md"]), %{
        "name" => "proj-agent",
        "description" => "Project agent"
      })

      agents = SubagentSupervisor.Agents.discover(project, home)

      agent = Enum.find(agents, &(&1.name == "proj-agent"))
      assert agent.name == "proj-agent"
      assert agent.source == :project
    end

    test "project-level agents shadow user-level with same name", %{
      user_home: home,
      project: project
    } do
      write_agent(Path.join([home, ".claude", "agents", "shared.md"]), %{
        "name" => "shared",
        "description" => "User version"
      })

      write_agent(Path.join([project, ".claude", "agents", "shared.md"]), %{
        "name" => "shared",
        "description" => "Project version"
      })

      agents = SubagentSupervisor.Agents.discover(project, home)

      agent = Enum.find(agents, &(&1.name == "shared"))
      assert agent.description == "Project version"
      assert agent.source == :project
    end

    test "returns agents from both levels", %{user_home: home, project: project} do
      write_agent(Path.join([home, ".claude", "agents", "global.md"]), %{
        "name" => "global",
        "description" => "Global agent"
      })

      write_agent(Path.join([project, ".claude", "agents", "local.md"]), %{
        "name" => "local",
        "description" => "Local agent"
      })

      agents = SubagentSupervisor.Agents.discover(project, home)
      names = Enum.map(agents, & &1.name) |> Enum.sort()
      assert "global" in names
      assert "local" in names
      assert "Explore" in names
      refute "statusline-setup" in names
    end

    test "returns built-in agents when no agent dirs exist", %{user_home: home} do
      agents = SubagentSupervisor.Agents.discover("/nonexistent", home)
      names = Enum.map(agents, & &1.name) |> Enum.sort()
      assert names == ["Explore", "Plan", "general-purpose"]
    end

    test "falls back to filename stem when name field is missing", %{user_home: home} do
      File.write!(
        Path.join([home, ".claude", "agents", "no-name-field.md"]),
        "---\ndescription: No name field\n---\nBody"
      )

      agents = SubagentSupervisor.Agents.discover("/nonexistent", home)
      assert Enum.any?(agents, &(&1.name == "no-name-field"))
    end

    test "handles malformed frontmatter gracefully", %{user_home: home} do
      File.write!(
        Path.join([home, ".claude", "agents", "bad-format.md"]),
        "no frontmatter here"
      )

      agents = SubagentSupervisor.Agents.discover("/nonexistent", home)
      # Falls back to filename stem
      assert Enum.any?(agents, &(&1.name == "bad-format"))
    end

    test "ignores files with empty name", %{user_home: home} do
      File.write!(
        Path.join([home, ".claude", "agents", "unnamed.md"]),
        "---\n---\nBody"
      )

      agents = SubagentSupervisor.Agents.discover("/nonexistent", home)
      # filename stem "unnamed" is used as fallback
      assert Enum.any?(agents, &(&1.name == "unnamed"))
    end

    test "includes dispatchable built-ins and filters setup agent", %{user_home: home} do
      agents = SubagentSupervisor.Agents.discover("/nonexistent", home)
      names = Enum.map(agents, & &1.name)

      assert "Explore" in names
      assert "Plan" in names
      assert "general-purpose" in names
      refute "statusline-setup" in names
    end
  end

  describe "find/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "agents-find-test-#{System.unique_integer([:positive])}")
      user_home = Path.join(tmp, "home")
      File.mkdir_p!(Path.join(user_home, ".claude/agents"))

      on_exit(fn -> File.rm_rf!(tmp) end)

      %{user_home: user_home}
    end

    test "returns ok when agent exists", %{user_home: home} do
      write_agent(Path.join([home, ".claude", "agents", "finder.md"]), %{
        "name" => "finder",
        "description" => "Find me"
      })

      # Temporarily override HOME
      old_home = System.get_env("HOME")
      System.put_env("HOME", home)

      on_exit(fn -> restore_env("HOME", old_home) end)

      assert {:ok, agent} = SubagentSupervisor.Agents.find("finder", nil)
      assert agent.name == "finder"
    end

    test "returns error when agent does not exist" do
      assert {:error, :not_found} = SubagentSupervisor.Agents.find("nonexistent", nil)
    end
  end

  describe "validate/2" do
    test "returns ok for valid agent" do
      tmp =
        Path.join(System.tmp_dir!(), "agents-validate-test-#{System.unique_integer([:positive])}")

      user_home = Path.join(tmp, "home")
      File.mkdir_p!(Path.join(user_home, ".claude/agents"))
      write_agent(Path.join([user_home, ".claude", "agents", "valid.md"]), %{"name" => "valid"})

      old_home = System.get_env("HOME")
      System.put_env("HOME", user_home)

      on_exit(fn ->
        restore_env("HOME", old_home)
        File.rm_rf!(tmp)
      end)

      assert {:ok, _} = SubagentSupervisor.Agents.validate("valid", nil)
    end

    test "returns ok for visible built-in agent" do
      assert {:ok, agent} = SubagentSupervisor.Agents.validate("Plan", nil)
      assert agent.source == :builtin
    end

    test "rejects filtered built-in agent" do
      assert {:error, {:not_found, "statusline-setup"}} =
               SubagentSupervisor.Agents.validate("statusline-setup", nil)
    end

    test "returns error with name for invalid agent" do
      assert {:error, {:not_found, "nope"}} = SubagentSupervisor.Agents.validate("nope", nil)
    end
  end

  describe "directory helpers" do
    test "user_agents_dir/1 returns correct path" do
      assert SubagentSupervisor.Agents.user_agents_dir("/home/user") ==
               "/home/user/.claude/agents"
    end

    test "project_agents_dir/1 returns correct path" do
      assert SubagentSupervisor.Agents.project_agents_dir("/proj") == "/proj/.claude/agents"
    end
  end

  defp write_agent(path, frontmatter) do
    fm_lines =
      Enum.map(frontmatter, fn {k, v} -> "#{k}: #{v}" end)
      |> Enum.join("\n")

    File.write!(path, "---\n#{fm_lines}\n---\nAgent body content")
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
