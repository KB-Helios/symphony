import Config

config :phoenix_live_view, :colocated_js, disable_symlink_warning: true

config :phoenix, :json_library, Jason

# In production, set SECRET_KEY_BASE env var (>=64 chars) to override this default.
# SymphonyElixir.HttpServer.secret_key_base/0 prefers the env var at runtime.
config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

if config_env() == :test do
  config :symphony_elixir,
    workflow_file_path: Path.expand("../test/fixtures/startup_workflow.md", __DIR__),
    install_signal_handler: false
end

# tailwind hex package is 0.5.1 (mix.lock) but wraps Tailwind CLI 4.1.12 — keep version as CLI version.
# assets/css/app.css uses `@import "tailwindcss"` which requires Tailwind >=4.
config :tailwind,
  version: "4.1.12",
  default: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :esbuild,
  version: "0.25.4",
  default: [
    args: ~w(
      assets/js/app.js
      --bundle
      --target=es2022
      --outdir=priv/static/assets
      --external:/fonts/*
      --external:/images/*
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]
