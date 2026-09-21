package main

// HLS packager for the phone-bridge fallback (docs/CASTING.md §6.5 Tier 3). Takes the
// host's H.264 access units, muxes them to MPEG-TS, and serves a rolling live
// playlist the Default Media Receiver can play — validated to work on the user's
// legacy Chromecast. No transcode: the encoder's Annex-B goes straight into PES.
//
// Carries a continuous AAC track (real computer audio via pushAAC when the host
// streams it, silence otherwise — the receiver needs an audio track to start).
// Segments break on keyframes; each segment carries PAT/PMT and (via the encoder)
// SPS/PPS, so it decodes independently.

import (
	"bytes"
	"context"
	"fmt"
	"math"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/asticode/go-astits"
	"github.com/pion/webrtc/v4/pkg/media/h264reader"
)

const (
	hlsVideoPID   = 256
	hlsAudioPID   = 257
	hlsTargetDur  = 2.0  // seconds per segment (break at the first keyframe past this)
	hlsWindow     = 5    // rolling segments kept in the live playlist
	aacFrameTicks = 1920 // one 1024-sample AAC-LC frame @ 48 kHz, in 90 kHz ticks
)

// silentAAC is one silent AAC-LC ADTS frame (48 kHz stereo). The Chromecast's
// Default Media Receiver will NOT start HLS playback without an audio track (a
// video-only stream sticks on LOADING forever), so we ALWAYS keep a continuous
// AAC track flowing. When real computer audio is arriving (pushAAC), each 1024-
// sample slot is filled with a real frame; silence only fills underrun gaps.
var silentAAC = []byte{0xff, 0xf1, 0x4c, 0x80, 0x01, 0xbf, 0xfc, 0x21, 0x10, 0x04, 0x60, 0x8c, 0x1c}

// hlsAACFIFOCap bounds the real-audio backlog (~1.7 s at 46.9 frames/s). If the
// host briefly outruns the video-driven slot drain we drop the OLDEST frame —
// staying near real-time matters more than not losing a few ms of audio.
const hlsAACFIFOCap = 80

type hlsSegment struct {
	name     string
	data     []byte
	duration float64
}

type hlsPackager struct {
	mu          sync.Mutex
	muxer       *astits.Muxer
	curBuf      *bytes.Buffer
	segStartPTS int64
	lastPTS     int64
	audioPTS90  int64 // next audio frame timestamp (regular 1024-sample cadence)
	audioBase   bool  // audioPTS90 anchored to the first video frame
	aacFIFO     [][]byte // real AAC-LC ADTS frames from the host, drained per slot
	seq         int          // next segment index
	segments    []hlsSegment // rolling window
	started     bool
}

// pushAAC queues one real AAC-LC ADTS frame (1024 samples) from the host. It's
// drained into the regular audio slot timeline in writeVideo; silence fills any
// slot the FIFO can't cover. Bounded so a burst can't grow unbounded.
func (h *hlsPackager) pushAAC(adts []byte) {
	if len(adts) == 0 {
		return
	}
	frame := make([]byte, len(adts))
	copy(frame, adts)
	h.mu.Lock()
	h.aacFIFO = append(h.aacFIFO, frame)
	if len(h.aacFIFO) > hlsAACFIFOCap {
		h.aacFIFO = h.aacFIFO[len(h.aacFIFO)-hlsAACFIFOCap:]
	}
	h.mu.Unlock()
}

func newHLSPackager() *hlsPackager { return &hlsPackager{} }

// writeVideo muxes one H.264 access unit (Annex-B). ptsUS is microseconds.
func (h *hlsPackager) writeVideo(annexB []byte, ptsUS uint64, keyframe bool) {
	pts90 := int64(ptsUS) * 9 / 100 // µs → 90 kHz
	h.mu.Lock()
	defer h.mu.Unlock()

	if h.muxer == nil {
		if !keyframe {
			return // a live playlist must start on a keyframe
		}
		h.startSegment(pts90)
	} else if keyframe && float64(pts90-h.segStartPTS)/90000.0 >= hlsTargetDur {
		h.finishSegment(pts90)
		h.startSegment(pts90)
	}
	h.lastPTS = pts90

	// Keep a continuous AAC track flowing up to this video frame, so the Cast
	// receiver will actually play (it stalls forever on video-only HLS). Each slot
	// is one 1024-sample frame: a REAL frame from the host's FIFO when available,
	// silence otherwise. Both the slot drain (video-PTS-driven) and the host's AAC
	// production are wall-clock-paced at ~46.9 fps, so they stay balanced with no
	// drift — the FIFO just absorbs jitter.
	if !h.audioBase {
		h.audioPTS90 = pts90
		h.audioBase = true
	}
	for h.audioPTS90 <= pts90 {
		frame := silentAAC
		if len(h.aacFIFO) > 0 {
			frame = h.aacFIFO[0]
			h.aacFIFO = h.aacFIFO[1:]
		}
		_, _ = h.muxer.WriteData(&astits.MuxerData{
			PID: hlsAudioPID,
			PES: &astits.PESData{
				Header: &astits.PESHeader{
					StreamID: 0xC0, // audio stream
					OptionalHeader: &astits.PESOptionalHeader{
						MarkerBits:             2,
						PTSDTSIndicator:        astits.PTSDTSIndicatorOnlyPTS,
						PTS:                    &astits.ClockReference{Base: h.audioPTS90},
						DataAlignmentIndicator: true,
					},
				},
				Data: frame,
			},
		})
		h.audioPTS90 += aacFrameTicks
	}

	// Prepend an Access Unit Delimiter (NAL type 9). ffmpeg's TS muxer always
	// inserts one; without it a strict decoder (the Chromecast) can't delimit
	// access units — it reads the SPS+PPS as a pictureless AU and stalls.
	au := make([]byte, 0, len(annexB)+6)
	au = append(au, 0x00, 0x00, 0x00, 0x01, 0x09, 0xf0)
	au = append(au, annexB...)
	_, _ = h.muxer.WriteData(&astits.MuxerData{
		PID: hlsVideoPID,
		PES: &astits.PESData{
			Header: &astits.PESHeader{
				StreamID: 0xE0, // video stream
				OptionalHeader: &astits.PESOptionalHeader{
					MarkerBits:             2,
					PTSDTSIndicator:        astits.PTSDTSIndicatorOnlyPTS,
					PTS:                    &astits.ClockReference{Base: pts90},
					DataAlignmentIndicator: true,
				},
			},
			Data: au,
		},
	})
}

func (h *hlsPackager) startSegment(pts90 int64) {
	h.curBuf = &bytes.Buffer{}
	m := astits.NewMuxer(context.Background(), h.curBuf)
	_ = m.AddElementaryStream(astits.PMTElementaryStream{
		ElementaryPID: hlsVideoPID, StreamType: astits.StreamTypeH264Video})
	_ = m.AddElementaryStream(astits.PMTElementaryStream{
		ElementaryPID: hlsAudioPID, StreamType: astits.StreamTypeAACAudio})
	m.SetPCRPID(hlsVideoPID)
	_, _ = m.WriteTables()
	h.muxer = m
	h.segStartPTS = pts90
	h.started = true
}

func (h *hlsPackager) finishSegment(endPTS90 int64) {
	if h.curBuf == nil {
		return
	}
	dur := float64(endPTS90-h.segStartPTS) / 90000.0
	seg := hlsSegment{name: fmt.Sprintf("seg%d.ts", h.seq), data: h.curBuf.Bytes(), duration: dur}
	h.seq++
	h.segments = append(h.segments, seg)
	if len(h.segments) > hlsWindow {
		h.segments = h.segments[len(h.segments)-hlsWindow:]
	}
	h.muxer = nil
	h.curBuf = nil
	fmt.Fprintf(os.Stderr, "[hls] segment %s (%.2fs, %d bytes), window=%d\n", seg.name, seg.duration, len(seg.data), len(h.segments))
}

// playlist renders the live .m3u8 for the current window.
func (h *hlsPackager) playlist() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	maxDur := hlsTargetDur
	for _, s := range h.segments {
		if s.duration > maxDur {
			maxDur = s.duration
		}
	}
	firstSeq := h.seq - len(h.segments)
	var b strings.Builder
	b.WriteString("#EXTM3U\n#EXT-X-VERSION:3\n")
	fmt.Fprintf(&b, "#EXT-X-TARGETDURATION:%d\n", int(math.Ceil(maxDur)))
	fmt.Fprintf(&b, "#EXT-X-MEDIA-SEQUENCE:%d\n", firstSeq)
	for _, s := range h.segments {
		fmt.Fprintf(&b, "#EXTINF:%.3f,\n%s\n", s.duration, s.name)
	}
	return b.String()
}

func (h *hlsPackager) segment(name string) ([]byte, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, s := range h.segments {
		if s.name == name {
			return s.data, true
		}
	}
	return nil, false
}

func (h *hlsPackager) ready() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.segments) >= 2 // enough buffered for the receiver to start cleanly
}

// register wires the packager into an http mux: /live.m3u8 + /segN.ts (relative
// segment URLs in the playlist resolve against the .m3u8 URL). One root handler
// because ServeMux can't prefix-match bare "segN.ts" names.
func (h *hlsPackager) register(mux *http.ServeMux) {
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(os.Stderr, "[hls] %s %s from %s\n", r.Method, r.URL.Path, r.RemoteAddr)
		w.Header().Set("Access-Control-Allow-Origin", "*")
		switch {
		case r.URL.Path == "/live.m3u8":
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			w.Header().Set("Cache-Control", "no-cache")
			_, _ = w.Write([]byte(h.playlist()))
		case strings.HasPrefix(r.URL.Path, "/seg") && strings.HasSuffix(r.URL.Path, ".ts"):
			if data, ok := h.segment(strings.TrimPrefix(r.URL.Path, "/")); ok {
				w.Header().Set("Content-Type", "video/mp2t")
				_, _ = w.Write(data)
			} else {
				http.NotFound(w, r)
			}
		default:
			http.NotFound(w, r)
		}
	})
}

// primaryLANIP returns the source IP the OS uses to reach the LAN/internet — the
// address a Chromecast on the same network can fetch segments from.
func primaryLANIP() string {
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		return ""
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.UDPAddr).IP.String()
}

// feedH264ToHLS loops an Annex-B file into the packager at fps (real-time),
// grouping NALs into access units and flagging keyframes (IDR).
func feedH264ToHLS(pkg *hlsPackager, file string, fps int) {
	frameDur := time.Second / time.Duration(fps)
	var ptsUS uint64
	for {
		f, err := os.Open(file)
		if err != nil {
			return
		}
		reader, err := h264reader.NewReader(f)
		if err != nil {
			f.Close()
			return
		}
		var au []byte
		haveVCL, isKey := false, false
		ticker := time.NewTicker(frameDur)
		flush := func() {
			if len(au) > 0 {
				<-ticker.C
				pkg.writeVideo(au, ptsUS, isKey)
				ptsUS += uint64(frameDur.Microseconds())
			}
			au, haveVCL, isKey = nil, false, false
		}
		for {
			nal, err := reader.NextNAL()
			if err != nil {
				break
			}
			t := nal.UnitType
			vcl := t >= 1 && t <= 5
			if vcl && haveVCL {
				flush()
			}
			au = append(au, 0, 0, 0, 1)
			au = append(au, nal.Data...)
			if vcl {
				haveVCL = true
			}
			if t == 5 {
				isKey = true // IDR
			}
		}
		flush()
		ticker.Stop()
		f.Close()
	}
}

// runHLSTest de-risks the muxer: serve testpattern.h264 as live HLS on the LAN
// and LOAD it to the device, printing MEDIA_STATUS. Proves the receiver plays
// OUR-muxed HLS (not just a public sample).
func runHLSTest(deviceIP, file string) {
	pkg := newHLSPackager()
	mux := http.NewServeMux()
	pkg.register(mux)
	ln, err := net.Listen("tcp", ":0")
	if err != nil {
		fmt.Println("FAIL listen:", err)
		os.Exit(1)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	go func() { _ = http.Serve(ln, mux) }()
	lanIP := primaryLANIP()
	url := fmt.Sprintf("http://%s:%d/live.m3u8", lanIP, port)
	fmt.Fprintf(os.Stderr, "[hls] serving %s\n", url)

	go feedH264ToHLS(pkg, file, 24)
	for i := 0; i < 100 && !pkg.ready(); i++ {
		time.Sleep(100 * time.Millisecond)
	}
	c := newCastV2("CC1AD845", castNamespace, nil)
	if err := c.connect(deviceIP, 8009); err != nil {
		fmt.Println("FAIL connect:", err)
		os.Exit(1)
	}
	if err := c.launch(10 * time.Second); err != nil {
		fmt.Println("FAIL launch:", err)
		os.Exit(1)
	}
	if err := c.load(url, "application/vnd.apple.mpegurl", "LIVE", "Remotype HLS"); err != nil {
		fmt.Println("FAIL load:", err)
		os.Exit(1)
	}
	// Poll playback state so we get an explicit PLAYING (not just segment fetches).
	for i := 0; i < 6; i++ {
		time.Sleep(3 * time.Second)
		c.mediaGetStatus()
	}
	c.stop()
}
