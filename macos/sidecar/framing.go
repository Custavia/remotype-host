package main

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
)

// Media frame kinds on the Swift→sidecar unix socket.
const (
	kindVideo    = 1 // H.264 access unit, Annex-B (one coded frame per frame)
	kindAudio    = 2 // PCM: interleaved stereo Int16 little-endian, 48 kHz (WebRTC/Opus path)
	kindAudioAAC = 3 // one AAC-LC ADTS frame (1024 samples @ 48 kHz) for the HLS mux
)

// Wire framing (docs/CASTING.md §7.4 BRIDGE media socket, reused locally):
//
//	u32 len   (big-endian) = 1 + 8 + len(payload)
//	u8  kind
//	u64 ptsUS (big-endian) = presentation timestamp, microseconds (mach clock)
//	payload[len-9]
//
// A 16 MiB ceiling guards against a desync turning a bad length into a huge alloc.
const maxFrameLen = 16 << 20

type mediaFrame struct {
	kind    byte
	ptsUS   uint64
	payload []byte
}

// readFrame reads one length-prefixed frame. Returns io.EOF at a clean end.
func readFrame(r *bufio.Reader) (mediaFrame, error) {
	var hdr [4]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return mediaFrame{}, err
	}
	n := binary.BigEndian.Uint32(hdr[:])
	if n < 9 || n > maxFrameLen {
		return mediaFrame{}, fmt.Errorf("media frame length out of range: %d", n)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return mediaFrame{}, err
	}
	return mediaFrame{
		kind:    buf[0],
		ptsUS:   binary.BigEndian.Uint64(buf[1:9]),
		payload: buf[9:],
	}, nil
}
