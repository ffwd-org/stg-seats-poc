package intent

import (
	"encoding/binary"
	"fmt"
)

// HoldIntent represents a seat hold operation — 32 bytes on the wire.
type HoldIntent struct {
	EventID   uint64  // 8 bytes
	SeatID    uint32  // 4 bytes
	UserID    uint64  // 8 bytes
	HoldTTL   uint16  // 2 bytes (seconds)
	Timestamp uint64  // 8 bytes (unix nanos)
	_pad      [2]byte // 2 bytes padding → total 32
}

const IntentSize = 32

// Encode encodes a HoldIntent into buf (must be >= 32 bytes).
// Zero-allocation: caller provides the buffer.
func Encode(h *HoldIntent, buf []byte) {
	_ = buf[IntentSize-1] // bounds check hint
	binary.LittleEndian.PutUint64(buf[0:8], h.EventID)
	binary.LittleEndian.PutUint32(buf[8:12], h.SeatID)
	binary.LittleEndian.PutUint64(buf[12:20], h.UserID)
	binary.LittleEndian.PutUint16(buf[20:22], h.HoldTTL)
	binary.LittleEndian.PutUint64(buf[22:30], h.Timestamp)
	// bytes 30-31 are padding, zero them
	buf[30] = 0
	buf[31] = 0
}

// Decode decodes a 32-byte slice back into a HoldIntent.
func Decode(b []byte) (*HoldIntent, error) {
	if len(b) < IntentSize {
		return nil, fmt.Errorf("intent: buffer too short: %d bytes (need %d)", len(b), IntentSize)
	}
	h := &HoldIntent{
		EventID:   binary.LittleEndian.Uint64(b[0:8]),
		SeatID:    binary.LittleEndian.Uint32(b[8:12]),
		UserID:    binary.LittleEndian.Uint64(b[12:20]),
		HoldTTL:   binary.LittleEndian.Uint16(b[20:22]),
		Timestamp: binary.LittleEndian.Uint64(b[22:30]),
	}
	return h, nil
}
