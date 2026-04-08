defmodule StgSeats.Hub do
  @moduledoc """
  Hub GenServer -- provides a unified API over all section actors.
  Handles:
    - get_or_start_section(section_id) -- ensures a section actor exists
    - hold/best_available/release -- delegates to the right section actor
    - seed_section -- initializes a section with fragmentation
    - broadcast/subscribe/unsubscribe -- fans out to WS connections
  """
  use GenServer

  # --- Client API ---

  def start_link(arg \\ []), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @doc "Ensure a section actor is running. Returns :ok or {:error, reason}."
  def get_or_start_section(section_id) do
    get_or_start_section(section_id, 5_000)
  end

  def get_or_start_section(section_id, seats_per_section) do
    case Registry.lookup(StgSeats.SectionRegistry, {:section, section_id}) do
      [{_pid, _}] ->
        :ok

      [] ->
        spec = {StgSeats.SeatActor, {section_id, seats_per_section}}

        case DynamicSupervisor.start_child(StgSeats.SectionSupervisor, spec) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Seed a section with seats and optional fragmentation"
  def seed_section(section_id, seats_per_section, fragmentation_pct \\ 0) do
    :ok = get_or_start_section(section_id, seats_per_section)

    if fragmentation_pct > 0 do
      StgSeats.SeatActor.seed(section_id, fragmentation_pct)
    else
      {:ok, 0}
    end
  end

  @doc "Hold contiguous seats in a section"
  def hold(section_id, quantity, hold_token, ttl_seconds) do
    :ok = get_or_start_section(section_id)
    StgSeats.SeatActor.hold(section_id, quantity, hold_token, ttl_seconds)
  end

  @doc "Hold specific seats by their full IDs (e.g., [\"sec000:seat00042\"])"
  def hold_seats(seat_ids, holder, ttl_seconds) do
    # Group seat_ids by section
    grouped =
      seat_ids
      |> Enum.map(&parse_seat_id/1)
      |> Enum.group_by(fn {section_id, _idx} -> section_id end, fn {_section_id, idx} -> idx end)

    results =
      Enum.map(grouped, fn {section_id, indices} ->
        :ok = get_or_start_section(section_id)
        StgSeats.SeatActor.hold_seats(section_id, indices, holder, ttl_seconds)
      end)

    # Combine results
    case Enum.find(results, fn r -> match?({:error, _}, r) end) do
      nil ->
        all_ids = Enum.flat_map(results, fn {:ok, ids} -> ids end)
        {:ok, all_ids}

      error ->
        error
    end
  end

  @doc "Find best available contiguous seats in a section"
  def best_available(section_id, quantity) do
    :ok = get_or_start_section(section_id)
    StgSeats.SeatActor.best_available(section_id, quantity)
  end

  @doc "Release specific seat by index"
  def release(section_id, seat_indices) do
    case Registry.lookup(StgSeats.SectionRegistry, {:section, section_id}) do
      [{_pid, _}] -> StgSeats.SeatActor.release(section_id, seat_indices)
      [] -> {:error, :not_found}
    end
  end

  @doc "Release seats by their full IDs"
  def release_seats(seat_ids) do
    grouped =
      seat_ids
      |> Enum.map(&parse_seat_id/1)
      |> Enum.group_by(fn {section_id, _idx} -> section_id end, fn {_section_id, idx} -> idx end)

    Enum.each(grouped, fn {section_id, indices} ->
      release(section_id, indices)
    end)

    :ok
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
    {:ok, %{subscriptions: %{}}}
  end

  @impl true
  def handle_cast({:subscribe, event_id, ws_pid}, state) do
    new_subs =
      Map.update(state.subscriptions, event_id, [ws_pid], fn list ->
        if ws_pid in list, do: list, else: [ws_pid | list]
      end)

    {:noreply, %{state | subscriptions: new_subs}}
  end

  @impl true
  def handle_cast({:unsubscribe, event_id, ws_pid}, state) do
    new_subs =
      Map.update(state.subscriptions, event_id, [], fn list ->
        List.delete(list, ws_pid)
      end)

    {:noreply, %{state | subscriptions: new_subs}}
  end

  @impl true
  def handle_cast({:broadcast, event_id, message}, state) do
    case Map.get(state.subscriptions, event_id, []) do
      [] ->
        :ok

      pids ->
        Enum.each(pids, fn pid ->
          send(pid, {:broadcast, message})
        end)
    end

    {:noreply, state}
  end

  # --- Private Helpers ---

  defp parse_seat_id(seat_id) when is_binary(seat_id) do
    # Format: "sec000:seat00042"
    case String.split(seat_id, ":") do
      ["sec" <> sec_str, "seat" <> idx_str] ->
        {String.to_integer(sec_str), String.to_integer(idx_str)}

      _ ->
        {0, 0}
    end
  end
end
