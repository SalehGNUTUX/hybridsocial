# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :hybridsocial,
  ecto_repos: [Hybridsocial.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  env: config_env(),
  nats_url: "nats://localhost:4222",
  nats_host: "localhost",
  nats_port: 4222,
  nats_monitoring_port: 8222

# Register custom MIME types so Phoenix's `accepts` plug recognizes
# them. event-stream covers SSE; the two ActivityPub types are
# required so federation actor + collection endpoints can negotiate
# Content-Type without Phoenix 406-ing the request.
config :mime, :types, %{
  "text/event-stream" => ["event-stream"],
  "application/activity+json" => ["activity+json"],
  "application/ld+json" => ["ld+json"]
}

# Configure the endpoint
config :hybridsocial, HybridsocialWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: HybridsocialWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Hybridsocial.PubSub,
  live_view: [signing_salt: "TTdY2MXz"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# ExAws S3 configuration
config :ex_aws,
  access_key_id: [{:system, "S3_ACCESS_KEY_ID"}, :instance_role],
  secret_access_key: [{:system, "S3_SECRET_ACCESS_KEY"}, :instance_role],
  region: {:system, "S3_REGION"}

# Swoosh mailer configuration
config :hybridsocial, Hybridsocial.Mailer, adapter: Swoosh.Adapters.Local

# HTTP client for API-based mail adapters (Resend). Without this Swoosh
# defaults to Finch (not a dependency) and API delivery fails; hackney is
# already pulled in, so use it. Ignored by the Local/Test adapters.
config :swoosh, :api_client, Swoosh.ApiClient.Hackney

# Valkey (Redis-compatible) cache
config :hybridsocial, :valkey_url, "redis://localhost:6379"

# OpenSearch configuration
config :hybridsocial, :opensearch_url, "http://localhost:9200"
config :hybridsocial, :search_backend, "postgresql"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
