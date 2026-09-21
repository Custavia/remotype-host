package main

// Opus encode via cgo libopus — macOS ships no Opus encoder and pion/opus is
// decode-only, so the encode lives here (docs/CASTING.md §6.2: 48 kHz stereo, 96 kbps).
// Variadic opus_encoder_ctl can't be called from cgo directly, so bitrate is set
// through a tiny C shim.

// Statically link the vendored libopus (third_party/opus/) so the shipped helper
// has NO runtime dependency on a Homebrew dylib. Refresh with vendor-opus.sh.
// The blank line below is load-bearing: only the comment group touching
// `import "C"` is the cgo C preamble.

// #cgo CFLAGS: -I${SRCDIR}/third_party/opus/include
// #cgo LDFLAGS: ${SRCDIR}/third_party/opus/lib/libopus.a
// #include <opus.h>
// #include <stdlib.h>
// static int rt_set_bitrate(OpusEncoder *e, int br) { return opus_encoder_ctl(e, OPUS_SET_BITRATE(br)); }
import "C"
import (
	"fmt"
	"unsafe"
)

const (
	opusSampleRate = 48000
	opusChannels   = 2
	opusFrameMS    = 20
	// 960 samples/channel per 20 ms frame at 48 kHz.
	opusFrameSamples = opusSampleRate / 1000 * opusFrameMS
	opusBitrate      = 96000
)

type opusEncoder struct {
	enc *C.OpusEncoder
}

func newOpusEncoder() (*opusEncoder, error) {
	var cerr C.int
	// OPUS_APPLICATION_RESTRICTED_LOWDELAY (2051): lowest algorithmic delay, right
	// for a live screen cast where lip-sync (§6.3) matters more than a few % rate.
	enc := C.opus_encoder_create(opusSampleRate, opusChannels, 2051, &cerr)
	if enc == nil || cerr != 0 {
		return nil, fmt.Errorf("opus_encoder_create failed: %d", int(cerr))
	}
	if r := C.rt_set_bitrate(enc, opusBitrate); r != 0 {
		C.opus_encoder_destroy(enc)
		return nil, fmt.Errorf("opus set bitrate failed: %d", int(r))
	}
	return &opusEncoder{enc: enc}, nil
}

// encode takes exactly opusFrameSamples*opusChannels interleaved Int16 samples
// and returns one Opus packet.
func (o *opusEncoder) encode(pcm []int16) ([]byte, error) {
	if len(pcm) != opusFrameSamples*opusChannels {
		return nil, fmt.Errorf("opus encode: want %d samples, got %d", opusFrameSamples*opusChannels, len(pcm))
	}
	out := make([]byte, 4000) // max sensible Opus packet at 96 kbps/20 ms
	n := C.opus_encode(o.enc,
		(*C.opus_int16)(unsafe.Pointer(&pcm[0])),
		C.int(opusFrameSamples),
		(*C.uchar)(unsafe.Pointer(&out[0])),
		C.opus_int32(len(out)))
	if n < 0 {
		return nil, fmt.Errorf("opus_encode failed: %d", int(n))
	}
	return out[:n], nil
}

func (o *opusEncoder) close() {
	if o.enc != nil {
		C.opus_encoder_destroy(o.enc)
		o.enc = nil
	}
}
