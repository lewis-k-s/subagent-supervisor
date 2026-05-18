import Config

config :subagent_supervisor, :allowed_launchers, ["bash"]
config :subagent_supervisor, :state_dir, Path.join(System.tmp_dir!(), "subagent_supervisor_test")
