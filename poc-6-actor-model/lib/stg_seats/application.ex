defmodule StgSeats.Application do
  @moduledoc """
  OTP Application for stg-seats Elixir actor model.
  Supervision tree:
    Registry + DynamicSupervisor + Hub GenServer + Bandit HTTP
  """
  use Application

  @impl true
  def start(_type, _args) do
    # Create ETS tables for concurrent seat-state reads (bypasses GenServer mailbox)
    :ets.new(:venue_seats, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(:venue_rows, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(:venue_meta, [:set, :public, :named_table, read_concurrency: true])

    children = [
      # Registry: maps section_id -> section actor pids
      {Registry, keys: :unique, name: StgSeats.SectionRegistry},
      # DynamicSupervisor: starts section actors on demand
      {DynamicSupervisor, name: StgSeats.SectionSupervisor, strategy: :one_for_one},
      # Hub: aggregated broadcast and seat state management
      StgSeats.Hub,
      # HTTP server
      {Bandit, plug: StgSeats.Router, port: 4000}
    ]

    opts = [strategy: :one_for_one, name: StgSeats.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
