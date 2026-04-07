import Config

config :stg_seats,
  num_sections: 20,
  seats_per_section: 5_000,
  telemetry_report_interval: 5_000

config :logger, level: :info
