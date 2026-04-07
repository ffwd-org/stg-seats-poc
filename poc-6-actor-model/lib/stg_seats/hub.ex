defmodule StgSeats.Hub do
  @moduledoc """
  Hub GenServer — provides a unified API over all section actors.
  Handles:
    - get_or_start_section(section_id) — ensures a section actor exists
    - hold(event_id, seat_index, ...) — delegates to the right section
    - broadcast(event_id, message) — fans out to all subscribed WS connections
    - subscribe(event_id, ws_pid) — track a WS connection's interest in an event
  """
  use GenServer

  # Section count: 20 sections × 5,000 seats = 100,000
  @num_sections 20
  @seats_per_section 5_000

  # --- Client API ---

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @doc "Ensure a section actor is running for this event's section"
  def get_or_start_section(section_id) do
    spec = %{id: StgSeats.SeatActor, start: {StgSeats.SeatActor, :start_link, [section_id]}}
    DynamicSupervisor.start_child(StgSeats.SectionSupervisor, spec)

    StgSeats.SeatActor.via_tuple(section_id)
  end

  @doc "Hold a seat in a section"
  def hold(section_id, quantity, hold_token, ttl_seconds) do
    {:ok, _pid} = get_or_start_section(section_id)
    StgSeats.SeatActor.hold(section_id, quantity, hold_token, ttl_seconds)
  end

  @doc "Release a seat"
  def release(section_id, seat_index) do
    case Registry.lookup(StgSeats.HubRegistry, {:section, section_id}) do
      [{pid, _}] -> GenServer.call(pid, {:release, seat_index})
      [] -> {:error, :not_found}
    end
  end

  @doc "Subscribe a WebSocket process to an event channel"
  def subscribe(event_id, ws_pid) do
    GenServer.cast(__MODULE__, {:subscribe, event_id, ws_pid})
  end

  @doc "Unsubscribe a WebSocket process"
  def unsubscribe(event_id, ws_pid) do
    GenServer.cast(__MODULE__, {:unsubscribe, event_id, ws_pid})
  end

  @doc "Broadcast to all subscribed WS connections for an event"
  def broadcast(event_id, message) do
    GenServer.cast(__MODULE__, {:broadcast, event_id, message})
  end

  # --- Server Implementation ---

  @impl true
  def init(_arg) do
    # event_id => [ws_pid, ...]
    subscriptions = %{}
    {:ok, subscriptions}
  end

  @impl true
  def handle_cast({:subscribe, event_id, ws_pid}, subscriptions) do
    # Track ws_pid's interest in event_id
    new_subs =
      Map.update(subscriptions, event_id, [ws_pid], fn list ->
        if ws_pid in list, do: list, else: list ++ [ws_pid]
      end)

    {:noreply, new_subs}
  end

  @impl true
  def handle_cast({:unsubscribe, event_id, ws_pid}, subscriptions) do
    new_subs =
      Map.update(subscriptions, event_id, [], fn list ->
        List.delete(list, ws_pid)
      end)

    {:noreply, new_subs}
  end

  @impl true
  def handle_cast({:broadcast, event_id, message}, subscriptions) do
    # Send to all subscribed WS processes
    case Map.get(subscriptions, event_id, []) do
      [] ->
        :ok

      pids ->
        Enum.each(pids, fn pid ->
          send(pid, {:broadcast, message})
        end)
    end

    {:noreply, subscriptions}
  end

  @impl true
  def handle_call({:hold, section_id, quantity, hold_token, ttl}, _from, state) do
    result = hold(section_id, quantity, hold_token, ttl)
    {:reply, result, state}
  end

  # Map event_id to section_id: event_id % @num_sections
  def section_for_event(event_id), do: rem(event_id, @num_sections)
end
