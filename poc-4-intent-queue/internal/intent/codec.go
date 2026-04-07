package intent

import (
	"encoding/binary"
	"fmt"
)

// HoldIntent represents a seat hold operation.
type HoldIntent struct {
	EventID    uint64
	SeatID     uint64
	HoldToken  [16]byte
	TTLSeconds uint32
	NowUnix    uint64
}

// Encode encodes a HoldIntent into 44 bytes:
// - eventID: 8 bytes (uint64, BE)
// - seatID: 8 bytes (uint64, BE)
// - holdToken: 16 bytes
// - ttl: 4 bytes (uint32, BE)
// - now: 8 bytes (uint64, BE)
func Encode(h *HoldIntent) []byte {
	b := make([]byte, 44)
	binary.BigEndian.PutUint64(b[0:8], h.EventID)
	binary.BigEndian.PutUint64(b[8:16], h.SeatID)
	copy(b[16:32], h.HoldToken[:])
	binary.BigEndian.PutUint32(b[32:36], h.TTLSeconds)
	binary.BigEndian.PutUint64(b[36:44], h.NowUnix)
	return b
}

// Decode decodes a 44-byte slice back into a HoldIntent.
func Decode(b []byte) (*HoldIntent, error) {
	if len(b) < 44 {
		return nil, fmt.Errorf("intent: buffer too short: %d bytes", len(b))
	}
	h := &HoldIntent{
		EventID:    binary.BigEndian.Uint64(b[0:8]),
		SeatID:     binary.BigEndian.Uint64(b[8:16]),
		TTLSeconds: binary.BigEndian.Uint32(b[32:36]),
		NowUnix:    binary.BigEndian.Uint64(b[36:44]),
	}
	copy(h.HoldToken[:], b[16:32])
	return h, nil
}
