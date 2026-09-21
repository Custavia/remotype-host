// remotype-cast-helper — the Go/Pion WebRTC + CASTv2 sidecar for the macOS
// Remotype host's Cast DIRECT path (docs/CASTING.md §6.5 Tier 1). The Swift host
// captures + VideoToolbox-encodes H.264 and feeds Annex-B NALs + stereo PCM over
// a local socket; this process owns the RTCPeerConnection (offerer), packetizes
// to RTP (Opus-encoding the audio), and relays SDP/ICE as JSON lines on stdio
// that Server.swift forwards over the cast.sig channel.
//
//	real mode: remotype-cast-helper --media-socket <path>
//	           control: newline-JSON on stdin/stdout; media: the unix socket.
//	selftest:  remotype-cast-helper --selftest
//	           offers a canned H.264 stream to a browser answerer (Chromium ==
//	           the Cast receiver engine) so the Pion→receiver path can be proven
//	           with no Chromecast and no Cast console App ID.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/pion/webrtc/v4"
)

func main() {
	selftest := flag.Bool("selftest", false, "run the browser loopback harness")
	addr := flag.String("addr", "127.0.0.1:50820", "selftest HTTP address")
	file := flag.String("file", "testpattern.h264", "H.264 Annex-B file for selftest")
	mediaSocket := flag.String("media-socket", "", "unix socket path Swift connects to for media frames")
	castprobe := flag.String("castprobe", "", "live CASTv2 check: <ip> (LAUNCHes -appid, prints status)")
	appID := flag.String("appid", "CC1AD845", "Cast receiver App ID for --castprobe")
	castload := flag.String("castload", "", "Tier-3 de-risk: <ip> — LOAD -url on the Default Media Receiver")
	loadURL := flag.String("url", "", "media URL for --castload")
	streamType := flag.String("streamtype", "BUFFERED", "LIVE|BUFFERED for --castload")
	hlstest := flag.String("hlstest", "", "Tier-3 muxer test: <ip> — serve -file as live HLS + LOAD it")
	caststatus := flag.String("caststatus", "", "print which app the sink <ip> is running")
	caststop := flag.String("caststop", "", "STOP whatever app the sink <ip> is running")
	flag.Parse()

	if *selftest {
		runSelftest(*addr, *file)
		return
	}
	if *castprobe != "" {
		runCastProbe(*castprobe, *appID)
		return
	}
	if *castload != "" {
		runCastLoad(*castload, *loadURL, *streamType)
		return
	}
	if *caststatus != "" {
		runCastStatus(*caststatus)
		return
	}
	if *caststop != "" {
		runCastStop(*caststop)
		return
	}
	if *hlstest != "" {
		runHLSTest(*hlstest, *file)
		return
	}
	if *mediaSocket == "" {
		fmt.Fprintln(os.Stderr, "remotype-cast-helper: need --media-socket <path> (or --selftest)")
		os.Exit(2)
	}
	runSession(*mediaSocket)
}

// newAPI builds a plain API pinned to the Cast codecs (H.264 Constrained Baseline
// per §6.5 + Opus). Used by --selftest; the real session builds its own API with
// LAN ICE filtering and send-side BWE (see session.go).
func newAPI(se *webrtc.SettingEngine) (*webrtc.API, error) {
	m := &webrtc.MediaEngine{}
	if err := registerCastCodecs(m); err != nil {
		return nil, err
	}
	opts := []func(*webrtc.API){webrtc.WithMediaEngine(m)}
	if se != nil {
		opts = append(opts, webrtc.WithSettingEngine(*se))
	}
	return webrtc.NewAPI(opts...), nil
}
