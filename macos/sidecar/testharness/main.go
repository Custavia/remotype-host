// testharness — automated end-to-end check of the cast helper's REAL mode.
// Spawns remotype-cast-helper, plays the Swift host's role over stdio (start →
// offer → answer → ICE relay) with a Pion answerer standing in for the receiver,
// streams the canned H.264 test file over the media socket, and asserts that
// video (and, with -audio, Opus) RTP actually arrives. No browser, no Chromecast.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"sync/atomic"
	"time"

	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media/h264reader"
)

func main() {
	helper := flag.String("helper", "/tmp/cast-helper", "path to remotype-cast-helper binary")
	h264 := flag.String("file", "testpattern.h264", "H.264 Annex-B file to stream")
	audio := flag.Bool("audio", false, "also negotiate + require Opus audio")
	secs := flag.Int("secs", 5, "seconds to run before asserting")
	hls := flag.Bool("hls", false, "Tier-3 HLS mode: feed video, LOAD on -casthost")
	casthost := flag.String("casthost", "", "Chromecast IP for -hls")
	flag.Parse()

	sock := fmt.Sprintf("/tmp/remotype-cast-test-%d.sock", os.Getpid())
	cmd := exec.Command(*helper, "--media-socket", sock)
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	cmd.Stderr = os.Stderr
	must(cmd.Start(), "start helper")
	defer cmd.Process.Kill()

	enc := json.NewEncoder(stdin)
	send := func(m map[string]any) { must(enc.Encode(m), "send") }

	// HLS (Tier 3): send an hls start, feed video over the media socket, and let
	// the sidecar mux + LOAD it on the Chromecast. No WebRTC answerer.
	if *hls {
		defer stdin.Close() // keep stdin referenced so GC doesn't close it → helper EOF
		go func() {
			sc := bufio.NewScanner(stdout)
			sc.Buffer(make([]byte, 0, 64*1024), 4<<20)
			for sc.Scan() {
				fmt.Fprintf(os.Stderr, "[helper] %s\n", sc.Text())
			}
		}()
		send(map[string]any{"t": "start", "hls": true, "legacy": true,
			"computer": "Test Mac", "castHost": *casthost, "castPort": 8009, "appID": "CC1AD845"})
		var conn net.Conn
		var derr error
		for i := 0; i < 100; i++ {
			if conn, derr = net.Dial("unix", sock); derr == nil {
				break
			}
			time.Sleep(50 * time.Millisecond)
		}
		must(derr, "dial media socket")
		go streamVideo(conn, *h264, 24)
		time.Sleep(time.Duration(*secs) * time.Second)
		fmt.Println("HLS harness done — see [helper] logs + the TV")
		return
	}

	// Pion answerer standing in for the Cast receiver.
	pc, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	must(err, "answerer pc")
	var videoPkts, audioPkts int64
	pc.OnTrack(func(tr *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		codec := tr.Codec().MimeType
		fmt.Fprintf(os.Stderr, "[harness] ontrack %s\n", codec)
		for {
			if _, _, err := tr.ReadRTP(); err != nil {
				return
			}
			if codec == webrtc.MimeTypeOpus {
				atomic.AddInt64(&audioPkts, 1)
			} else {
				atomic.AddInt64(&videoPkts, 1)
			}
		}
	})
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c != nil {
			send(map[string]any{"t": "ice", "data": c.ToJSON()})
		}
	})
	pc.OnICEConnectionStateChange(func(s webrtc.ICEConnectionState) {
		fmt.Fprintf(os.Stderr, "[harness] answerer ICE: %s\n", s)
	})

	// Read helper stdout: offer + trickled host ICE.
	go func() {
		sc := bufio.NewScanner(stdout)
		sc.Buffer(make([]byte, 0, 64*1024), 4<<20)
		for sc.Scan() {
			var m struct {
				T    string          `json:"t"`
				Data json.RawMessage `json:"data"`
				ICE  string          `json:"ice"`
				BPS  int             `json:"bps"`
				Msg  string          `json:"msg"`
			}
			if json.Unmarshal(sc.Bytes(), &m) != nil {
				continue
			}
			switch m.T {
			case "offer":
				var sd webrtc.SessionDescription
				must(json.Unmarshal(m.Data, &sd), "parse offer")
				must(pc.SetRemoteDescription(sd), "setRemote offer")
				ans, err := pc.CreateAnswer(nil)
				must(err, "createAnswer")
				must(pc.SetLocalDescription(ans), "setLocal answer")
				send(map[string]any{"t": "answer", "data": pc.LocalDescription()})
			case "ice":
				var c webrtc.ICECandidateInit
				if json.Unmarshal(m.Data, &c) == nil {
					_ = pc.AddICECandidate(c)
				}
			case "bwe":
				fmt.Fprintf(os.Stderr, "[harness] bwe %d bps\n", m.BPS)
			case "ready":
				fmt.Fprintln(os.Stderr, "[harness] helper: media socket ready")
			case "error":
				fmt.Fprintf(os.Stderr, "[harness] helper error: %s\n", m.Msg)
			}
		}
	}()

	send(map[string]any{"t": "start", "fps": 24, "legacy": true, "audio": *audio, "computer": "Test Mac"})

	// Connect to the media socket (retry until the helper is listening) and stream.
	var conn net.Conn
	for i := 0; i < 100; i++ {
		if conn, err = net.Dial("unix", sock); err == nil {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	must(err, "dial media socket")
	go streamVideo(conn, *h264, 24)
	if *audio {
		go streamAudioTone(conn)
	}

	time.Sleep(time.Duration(*secs) * time.Second)
	v, a := atomic.LoadInt64(&videoPkts), atomic.LoadInt64(&audioPkts)
	fmt.Printf("RESULT: video RTP=%d audio RTP=%d\n", v, a)
	ok := v > 0 && (!*audio || a > 0)
	if ok {
		fmt.Println("PASS")
	} else {
		fmt.Println("FAIL")
		os.Exit(1)
	}
}

func streamVideo(conn net.Conn, file string, fps int) {
	frameDur := time.Second / time.Duration(fps)
	var pts uint64
	for {
		f, err := os.Open(file)
		if err != nil {
			return
		}
		r, err := h264reader.NewReader(f)
		if err != nil {
			f.Close()
			return
		}
		var au []byte
		haveVCL := false
		tick := time.NewTicker(frameDur)
		flush := func() {
			if len(au) > 0 {
				<-tick.C
				writeMediaFrame(conn, 1, pts, au)
				pts += uint64(frameDur.Microseconds())
			}
			au, haveVCL = nil, false
		}
		for {
			nal, err := r.NextNAL()
			if err != nil {
				break
			}
			isVCL := nal.UnitType >= 1 && nal.UnitType <= 5
			if isVCL && haveVCL {
				flush()
			}
			au = append(au, 0, 0, 0, 1)
			au = append(au, nal.Data...)
			if isVCL {
				haveVCL = true
			}
		}
		flush()
		tick.Stop()
		f.Close()
	}
}

// streamAudioTone sends a 440 Hz stereo Int16 tone as 10 ms PCM chunks so the
// helper's Opus repacketizer has something to encode.
func streamAudioTone(conn net.Conn) {
	const rate = 48000
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	var phase float64
	var pts uint64
	// 480 samples/channel per 10 ms.
	for range tick.C {
		buf := make([]byte, 480*2*2)
		for i := 0; i < 480; i++ {
			// crude sine without math import: triangle-ish is fine for a packet-count test
			phase += 0.06
			if phase > 1 {
				phase -= 2
			}
			s := int16(phase * 8000)
			for ch := 0; ch < 2; ch++ {
				o := (i*2 + ch) * 2
				buf[o] = byte(s)
				buf[o+1] = byte(s >> 8)
			}
		}
		writeMediaFrame(conn, 2, pts, buf)
		pts += 10000
	}
}

func writeMediaFrame(conn net.Conn, kind byte, ptsUS uint64, payload []byte) {
	n := 1 + 8 + len(payload)
	hdr := make([]byte, 4+9)
	hdr[0] = byte(n >> 24)
	hdr[1] = byte(n >> 16)
	hdr[2] = byte(n >> 8)
	hdr[3] = byte(n)
	hdr[4] = kind
	for i := 0; i < 8; i++ {
		hdr[5+i] = byte(ptsUS >> (56 - 8*i))
	}
	if _, err := conn.Write(hdr); err != nil {
		fmt.Fprintf(os.Stderr, "[feed] write hdr err: %v\n", err)
		return
	}
	if _, err := conn.Write(payload); err != nil {
		fmt.Fprintf(os.Stderr, "[feed] write payload err: %v\n", err)
		return
	}
	wcount++
	if wcount%48 == 1 {
		fmt.Fprintf(os.Stderr, "[feed] wrote frame %d\n", wcount)
	}
}

var wcount int

func must(err error, ctx string) {
	if err != nil {
		fmt.Fprintf(os.Stderr, "FATAL %s: %v\n", ctx, err)
		os.Exit(2)
	}
}
