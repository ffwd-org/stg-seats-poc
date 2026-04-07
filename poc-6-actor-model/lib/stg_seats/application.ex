defmodule StgSeats.Application do
  @moduledoc """
  OTP Application for stg-seats Elixir actor model.
  Supervision tree:
    StgSeats.Hub  (Registry + DynamicSupervisor + Hub GenServer)
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry: maps event_id → section actor pids
      {Registry, keys: :unique, name: StgSeats.HubRegistry},
      # DynamicSupervisor: starts section actors on demand
      {DynamicSupervisor, strategy: :one_for_one, name: StgSeats.SectionSupervisor},
      # Hub: aggregated broadcast and seat state management
      StgSeats.Hub
    ]

    opts = [strategy: :one_for_one, name: StgSeats.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
