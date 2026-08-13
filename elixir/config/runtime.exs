import Config

state_root = System.get_env("SYMPHONY_STATE_ROOT", "/var/lib/symphony/state")

config :symphony_elixir,
  runtime_state_path: Path.join(state_root, "runtime-state.json"),
  log_file: Path.join(state_root, "log/symphony.log")
