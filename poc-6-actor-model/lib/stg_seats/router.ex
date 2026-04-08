defmodule StgSeats.Router do
  @moduledoc """
  Plug.Router implementing the 6 spec endpoints:
    POST /seed            — Seed sections with seats
    POST /best-available  — Find best contiguous seats
    POST /hold            — Hold specific seats
    POST /release         — Release held seats
    GET  /metrics         — Prometheus metrics
    GET  /health          — Health check
  """
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  post "/seed" do
    # Body: %{"seats" => 100000, "sections" => 20, "fragmentation" => 50}
    body = conn.body_params
    sections = body["sections"] || 20
    seats = body["seats"] || 100_000
    seats_per_section = div(seats, sections)
    fragmentation = body["fragmentation"] || 0

    for section_id <- 0..(sections - 1) do
      StgSeats.Hub.seed_section(section_id, seats_per_section, fragmentation)
    end

    send_resp(conn, 200, Jason.encode!(%{ok: true, sections: sections, seats: seats}))
  end

  post "/best-available" do
    # Body: %{"quantity" => 2, "section" => "0"}
    body = conn.body_params
    quantity = body["quantity"] || 2
    section = parse_section(body["section"])

    case StgSeats.Hub.best_available(section, quantity) do
      {:ok, seat_ids} ->
        send_resp(conn, 200, Jason.encode!(%{ok: true, seats: seat_ids}))

      {:error, reason} ->
        send_resp(conn, 409, Jason.encode!(%{ok: false, error: to_string(reason)}))
    end
  end

  post "/hold" do
    # Body: %{"seat_ids" => [...], "holder" => "user1", "ttl_seconds" => 60}
    #   OR  %{"section_id" => 0, "quantity" => 2, "hold_token" => "user1", "ttl_seconds" => 60}
    body = conn.body_params

    result =
      cond do
        body["seat_ids"] ->
          seat_ids = body["seat_ids"]
          holder = body["holder"] || "anon"
          ttl = body["ttl_seconds"] || 60
          StgSeats.Hub.hold_seats(seat_ids, holder, ttl)

        body["section_id"] != nil ->
          section_id = body["section_id"]
          quantity = body["quantity"] || 2
          hold_token = body["hold_token"] || "anon"
          ttl = body["ttl_seconds"] || 60
          StgSeats.Hub.hold(section_id, quantity, hold_token, ttl)

        true ->
          {:error, :invalid_request}
      end

    case result do
      {:ok, seat_ids} ->
        send_resp(conn, 200, Jason.encode!(%{ok: true, seats: seat_ids}))

      {:error, reason} ->
        send_resp(conn, 409, Jason.encode!(%{ok: false, error: to_string(reason)}))
    end
  end

  post "/release" do
    # Body: %{"seat_ids" => [...]}
    body = conn.body_params
    seat_ids = body["seat_ids"] || []

    StgSeats.Hub.release_seats(seat_ids)
    send_resp(conn, 200, Jason.encode!(%{ok: true}))
  end

  get "/metrics" do
    # Placeholder for Prometheus metrics export
    send_resp(conn, 200, "# HELP stg_seats_up Application is running\n# TYPE stg_seats_up gauge\nstg_seats_up 1\n")
  end

  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --- Helpers ---

  defp parse_section(nil), do: 0
  defp parse_section(s) when is_integer(s), do: s
  defp parse_section(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end
end
