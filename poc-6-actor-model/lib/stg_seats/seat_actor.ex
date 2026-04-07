defmodule StgSeats.SeatActor do
  @moduledoc """
  One GenServer per section (20 sections for 100K seats = ~5K seats per actor).
  Manages seat state for all seats in a section:
    seat_id => {status, holder_token, expiry_ts}

  Timer-based expiry: if now > expiry, seat auto-releases.
  """
  use GenServer

  # 5,000 seats per section (20 sections × 5,000 = 100,000 total)
  @seats_per_section 5_000

  # --- Client API ---

  def start_link(section_id) do
    GenServer.start_link(__MODULE__, section_id, name: via_tuple(section_id))
  end

  def via_tuple(section_id) do
    {:via, Registry, {StgSeats.HubRegistry, {:section, section_id}}}
  end

  @doc "Attempt to hold `quantity` adjacent seats starting from `start_seat`"
  def hold(section_id, quantity, hold_token, ttl_seconds) do
    GenServer.call(via_tuple(section_id), {:hold, quantity, hold_token, ttl_seconds})
  end

  @doc "Release a specific seat"
  def release(section_id, seat_index) do
    GenServer.call(via_tuple(section_id), {:release, seat_index})
  end

  @doc "Find best available contiguous run of `quantity` seats near focal point"
  def best_available(section_id, quantity, focal_row \\ 0, focal_index \\ 0) do
    GenServer.call(via_tuple(section_id), {:best_available, quantity, focal_row, focal_index})
  end

  @doc "Count of currently held seats"
  def held_count(section_id) do
    GenServer.call(via_tuple(section_id), :held_count)
  end

  # --- Server Implementation ---

  @impl true
  def init(section_id) do
    # Initialize all seats as available: seat_index => :available
    seats = for i <- 0..(@seats_per_section - 1), into: %{}, do: {i, :available}
    schedule_expiry_check()
    {:ok, %{section_id: section_id, seats: seats}}
  end

  @impl true
  def handle_call({:hold, quantity, hold_token, ttl_seconds}, _from, state) do
    now = System.system_time(:second)
    expiry = now + ttl_seconds

    case find_contiguous(state.seats, quantity) do
      nil ->
        {:reply, {:error, :no_contiguous_block}, state}

      seat_indices ->
        # Atomically hold all seats in the run
        new_seats =
          Enum.reduce(seat_indices, state.seats, fn idx, acc ->
            Map.put(acc, idx, {:held, hold_token, expiry})
          end)

        seat_ids = Enum.map(seat_indices, &"seat:#{String.pad_integer(&1, 5)}")
        {:reply, {:ok, seat_ids}, %{state | seats: new_seats}}
    end
  end

  @impl true
  def handle_call({:release, seat_index}, _from, state) do
    new_seats = Map.put(state.seats, seat_index, :available)
    {:reply, :ok, %{state | seats: new_seats}}
  end

  @impl true
  def handle_call({:best_available, quantity, _focal_row, _focal_index}, _from, state) do
    # Simple: find first contiguous run of `quantity` available seats
    case find_contiguous(state.seats, quantity) do
      nil ->
        {:reply, {:error, :no_contiguous_block}, state}

      seat_indices ->
        seat_ids = Enum.map(seat_indices, &"seat:#{String.pad_integer(&1, 5)}")
        {:reply, {:ok, seat_ids}, state}
    end
  end

  @impl true
  def handle_call(:held_count, _from, state) do
    count =
      state.seats
      |> Map.values()
      |> Enum.count(fn
        :available -> false
        {:held, _, _} -> true
        _ -> false
      end)

    {:reply, count, state}
  end

  @impl true
  def handle_info(:expire_check, state) do
    now = System.system_time(:second)

    # Release expired holds
    new_seats =
      Enum.into(state.seats, %{}, fn {idx, value} ->
        case value do
          {:held, _token, expiry} when expiry <= now -> {idx, :available}
          _ -> {idx, value}
        end
      end)

    schedule_expiry_check()
    {:noreply, %{state | seats: new_seats}}
  end

  # --- Private Helpers ---

  defp find_contiguous(seats, quantity) do
    seats_list = Map.to_list(seats) |> Enum.sort_by(fn {k, _} -> k end)

    find_run(seats_list, quantity, [])
  end

  defp find_run([], _quantity, _acc) do
    nil
  end

  defp find_run([{_idx, :available} | rest], quantity, acc) do
    new_acc = acc
    if length(new_acc) + 1 >= quantity do
      Enum.take(new_acc ++ [{:pending, :available}], quantity) |> Enum.map(fn {k, _} -> k end)
    else
      find_run(rest, quantity, acc ++ [{List.first(rest), :available}])
    end
  end

  defp find_run([{idx, {:held, _, _}} | rest], quantity, acc) do
    if length(acc) >= quantity do
      Enum.take(acc, quantity) |> Enum.map(fn {k, _} -> k end)
    else
      find_run(rest, quantity, [])
    end
  end

  defp schedule_expiry_check do
    # Check every 5 seconds for expired holds
    Process.send_after(self(), :expire_check, 5_000)
  end
end
