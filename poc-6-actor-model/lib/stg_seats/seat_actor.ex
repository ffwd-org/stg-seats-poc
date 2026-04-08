defmodule StgSeats.SeatActor do
  @moduledoc """
  One GenServer per section (20 sections for 100K seats = ~5K seats per actor).
  Manages seat state for all seats in a section:
    seat_id => {status, holder_token, expiry_ts}

  Seat state is stored in ETS (:venue_seats) for concurrent reads.
  Mutations go through the GenServer to ensure atomicity.
  Timer-based expiry: if now > expiry, seat auto-releases.
  """
  use GenServer

  @default_seats_per_section 5_000

  # --- Client API ---

  def start_link({section_id, seats_per_section}) do
    GenServer.start_link(__MODULE__, {section_id, seats_per_section}, name: via_tuple(section_id))
  end

  def start_link(section_id) when is_integer(section_id) do
    GenServer.start_link(__MODULE__, {section_id, @default_seats_per_section}, name: via_tuple(section_id))
  end

  def via_tuple(section_id) do
    {:via, Registry, {StgSeats.SectionRegistry, {:section, section_id}}}
  end

  @doc "Attempt to hold `quantity` contiguous available seats"
  def hold(section_id, quantity, hold_token, ttl_seconds) do
    GenServer.call(via_tuple(section_id), {:hold, quantity, hold_token, ttl_seconds})
  end

  @doc "Hold specific seat indices by their IDs"
  def hold_seats(section_id, seat_indices, hold_token, ttl_seconds) do
    GenServer.call(via_tuple(section_id), {:hold_seats, seat_indices, hold_token, ttl_seconds})
  end

  @doc "Release specific seat indices"
  def release(section_id, seat_indices) when is_list(seat_indices) do
    GenServer.call(via_tuple(section_id), {:release, seat_indices})
  end

  def release(section_id, seat_index) when is_integer(seat_index) do
    GenServer.call(via_tuple(section_id), {:release, [seat_index]})
  end

  @doc "Find best available contiguous run of `quantity` seats near focal point"
  def best_available(section_id, quantity, focal_row \\ 0, focal_index \\ 0) do
    GenServer.call(via_tuple(section_id), {:best_available, quantity, focal_row, focal_index})
  end

  @doc "Count of currently held seats"
  def held_count(section_id) do
    GenServer.call(via_tuple(section_id), :held_count)
  end

  @doc "Seed section with a given fragmentation pattern (percentage of seats pre-held)"
  def seed(section_id, fragmentation_pct) do
    GenServer.call(via_tuple(section_id), {:seed, fragmentation_pct})
  end

  # --- Server Implementation ---

  @impl true
  def init({section_id, seats_per_section}) do
    # Initialize all seats as available in ETS
    for i <- 0..(seats_per_section - 1) do
      :ets.insert(:venue_seats, {{section_id, i}, :available})
    end

    # Store section metadata
    :ets.insert(:venue_meta, {{:section_size, section_id}, seats_per_section})

    schedule_expiry_check()
    {:ok, %{section_id: section_id, seats_per_section: seats_per_section}}
  end

  @impl true
  def handle_call({:hold, quantity, hold_token, ttl_seconds}, _from, state) do
    now = System.system_time(:second)
    expiry = now + ttl_seconds

    case find_contiguous(state.section_id, state.seats_per_section, quantity) do
      nil ->
        {:reply, {:error, :no_contiguous_block}, state}

      seat_indices ->
        # Atomically hold all seats in the run
        Enum.each(seat_indices, fn idx ->
          :ets.insert(:venue_seats, {{state.section_id, idx}, {:held, hold_token, expiry}})
        end)

        seat_ids = Enum.map(seat_indices, &format_seat_id(state.section_id, &1))
        {:reply, {:ok, seat_ids}, state}
    end
  end

  @impl true
  def handle_call({:hold_seats, seat_indices, hold_token, ttl_seconds}, _from, state) do
    now = System.system_time(:second)
    expiry = now + ttl_seconds

    # Verify all seats are available
    all_available =
      Enum.all?(seat_indices, fn idx ->
        case :ets.lookup(:venue_seats, {state.section_id, idx}) do
          [{{_, _}, :available}] -> true
          _ -> false
        end
      end)

    if all_available do
      Enum.each(seat_indices, fn idx ->
        :ets.insert(:venue_seats, {{state.section_id, idx}, {:held, hold_token, expiry}})
      end)

      seat_ids = Enum.map(seat_indices, &format_seat_id(state.section_id, &1))
      {:reply, {:ok, seat_ids}, state}
    else
      {:reply, {:error, :seats_not_available}, state}
    end
  end

  @impl true
  def handle_call({:release, seat_indices}, _from, state) do
    Enum.each(seat_indices, fn idx ->
      :ets.insert(:venue_seats, {{state.section_id, idx}, :available})
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:best_available, quantity, focal_row, focal_index}, _from, state) do
    # focal_index is the preferred center index; find the closest contiguous block
    case find_best_contiguous(state.section_id, state.seats_per_section, quantity, focal_index) do
      nil ->
        {:reply, {:error, :no_contiguous_block}, state}

      seat_indices ->
        seat_ids = Enum.map(seat_indices, &format_seat_id(state.section_id, &1))
        {:reply, {:ok, seat_ids}, state}
    end
  end

  @impl true
  def handle_call(:held_count, _from, state) do
    count =
      Enum.count(0..(state.seats_per_section - 1), fn i ->
        case :ets.lookup(:venue_seats, {state.section_id, i}) do
          [{{_, _}, {:held, _, _}}] -> true
          _ -> false
        end
      end)

    {:reply, count, state}
  end

  @impl true
  def handle_call({:seed, fragmentation_pct}, _from, state) do
    # Pre-hold a percentage of seats to simulate fragmentation
    total = state.seats_per_section
    to_hold = div(total * fragmentation_pct, 100)
    now = System.system_time(:second)
    expiry = now + 3600  # 1 hour hold for seeded seats

    # Randomly scatter held seats
    indices = Enum.take_random(0..(total - 1), to_hold)

    Enum.each(indices, fn idx ->
      :ets.insert(:venue_seats, {{state.section_id, idx}, {:held, "seed", expiry}})
    end)

    {:reply, {:ok, to_hold}, state}
  end

  @impl true
  def handle_info(:expire_check, state) do
    now = System.system_time(:second)

    # Scan ETS for expired holds in this section
    for i <- 0..(state.seats_per_section - 1) do
      case :ets.lookup(:venue_seats, {state.section_id, i}) do
        [{{_, _}, {:held, _token, expiry}}] when expiry <= now ->
          :ets.insert(:venue_seats, {{state.section_id, i}, :available})

        _ ->
          :ok
      end
    end

    schedule_expiry_check()
    {:noreply, state}
  end

  # --- Private Helpers ---

  @doc false
  defp find_contiguous(section_id, seats_per_section, quantity) do
    find_first_run(section_id, 0, seats_per_section, quantity, [], 0)
  end

  defp find_first_run(_section_id, idx, max, _quantity, _acc, _acc_len) when idx >= max do
    nil
  end

  defp find_first_run(section_id, idx, max, quantity, acc, acc_len) when idx < max do
    case :ets.lookup(:venue_seats, {section_id, idx}) do
      [{{_, _}, :available}] ->
        new_acc = acc ++ [idx]
        new_len = acc_len + 1

        if new_len >= quantity do
          # Check orphan rejection: don't leave a single isolated seat on either side
          candidate = Enum.take(new_acc, quantity)
          if orphan_ok?(section_id, candidate, max) do
            candidate
          else
            # Skip first element and continue
            [_ | rest_acc] = new_acc
            find_first_run(section_id, idx + 1, max, quantity, rest_acc, new_len - 1)
          end
        else
          find_first_run(section_id, idx + 1, max, quantity, new_acc, new_len)
        end

      _ ->
        # Seat is held/booked — reset accumulator
        find_first_run(section_id, idx + 1, max, quantity, [], 0)
    end
  end

  @doc false
  defp find_best_contiguous(section_id, seats_per_section, quantity, focal_index) do
    # Collect all contiguous runs, then pick the one closest to focal_index
    runs = collect_all_runs(section_id, 0, seats_per_section, quantity, [], 0, [])

    case runs do
      [] ->
        nil

      runs ->
        # Score each run by distance from focal point
        runs
        |> Enum.map(fn run ->
          center = Enum.sum(run) / length(run)
          distance = abs(center - focal_index)
          {distance, run}
        end)
        |> Enum.min_by(fn {distance, _run} -> distance end)
        |> elem(1)
    end
  end

  defp collect_all_runs(_section_id, idx, max, _quantity, _acc, _acc_len, runs) when idx >= max do
    runs
  end

  defp collect_all_runs(section_id, idx, max, quantity, acc, acc_len, runs) do
    case :ets.lookup(:venue_seats, {section_id, idx}) do
      [{{_, _}, :available}] ->
        new_acc = acc ++ [idx]
        new_len = acc_len + 1

        if new_len >= quantity do
          # Extract a valid run
          candidate = Enum.take(new_acc, quantity)

          if orphan_ok?(section_id, candidate, max) do
            # Record this run and slide the window
            [_ | rest] = new_acc
            collect_all_runs(section_id, idx + 1, max, quantity, rest, new_len - 1, [candidate | runs])
          else
            [_ | rest] = new_acc
            collect_all_runs(section_id, idx + 1, max, quantity, rest, new_len - 1, runs)
          end
        else
          collect_all_runs(section_id, idx + 1, max, quantity, new_acc, new_len, runs)
        end

      _ ->
        collect_all_runs(section_id, idx + 1, max, quantity, [], 0, runs)
    end
  end

  # Orphan rejection: don't accept a run if it leaves a single isolated seat on either side
  defp orphan_ok?(section_id, candidate, max_seats) do
    first = List.first(candidate)
    last = List.last(candidate)

    left_ok = check_no_orphan_left(section_id, first, max_seats)
    right_ok = check_no_orphan_right(section_id, last, max_seats)

    left_ok and right_ok
  end

  defp check_no_orphan_left(_section_id, 0, _max), do: true
  defp check_no_orphan_left(_section_id, 1, _max), do: true

  defp check_no_orphan_left(section_id, first, _max) do
    # The seat just before our block
    left = first - 1

    case :ets.lookup(:venue_seats, {section_id, left}) do
      [{{_, _}, :available}] ->
        # There's an available seat to the left. Check if it would be isolated.
        left2 = left - 1

        if left2 < 0 do
          # Only one seat to the left edge — it would be orphaned
          false
        else
          case :ets.lookup(:venue_seats, {section_id, left2}) do
            [{{_, _}, :available}] -> true  # has a neighbor, not orphaned
            _ -> false  # seat at left is isolated
          end
        end

      _ ->
        # Seat to the left is held/doesn't exist — no orphan issue
        true
    end
  end

  defp check_no_orphan_right(section_id, last, max) do
    right = last + 1

    if right >= max do
      true
    else
      case :ets.lookup(:venue_seats, {section_id, right}) do
        [{{_, _}, :available}] ->
          right2 = right + 1

          if right2 >= max do
            # Only one seat to the right edge — it would be orphaned
            false
          else
            case :ets.lookup(:venue_seats, {section_id, right2}) do
              [{{_, _}, :available}] -> true
              _ -> false
            end
          end

        _ ->
          true
      end
    end
  end

  defp format_seat_id(section_id, seat_index) do
    s = String.pad_leading(Integer.to_string(section_id), 3, "0")
    i = String.pad_leading(Integer.to_string(seat_index), 5, "0")
    "sec#{s}:seat#{i}"
  end

  defp schedule_expiry_check do
    # Check every 5 seconds for expired holds
    Process.send_after(self(), :expire_check, 5_000)
  end
end
