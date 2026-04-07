defmodule StgSeats.Codec do
  @moduledoc """
  Binary codec for seat state messages.
  Format (44 bytes per HoldIntent):
    event_id:    8 bytes (big endian uint64)
    section_id:  4 bytes (big endian uint32)
    seat_index:  4 bytes (big endian uint32)
    hold_token: 16 bytes
    ttl:         4 bytes (big endian uint32)
    now_unix:    8 bytes (big endian uint64)
  """

  @version 1

  def encode_hold(event_id, section_id, seat_index, hold_token, ttl_seconds) do
    now = System.system_time(:second)

    <<
      @version::8,
      event_id::64,
      section_id::32,
      seat_index::32,
      hold_token::binary-size(16),
      ttl_seconds::32,
      now::64
    >>
  end

  def decode_hold(<<
        @version::8,
        event_id::64,
        section_id::32,
        seat_index::32,
        hold_token::binary-size(16),
        ttl_seconds::32,
        now::64
      >>) do
    {:ok,
     %{
       event_id: event_id,
       section_id: section_id,
       seat_index: seat_index,
       hold_token: hold_token,
       ttl_seconds: ttl_seconds,
       now_unix: now
     }}
  end

  def decode_hold(_), do: {:error, :invalid_frame}
end
