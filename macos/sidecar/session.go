package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/pion/interceptor"
	"github.com/pion/interceptor/pkg/cc"
	"github.com/pion/interceptor/pkg/gcc"
	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

// ---- stdio control protocol (newline-delimited JSON) --------------------------
//
// Swift → sidecar (stdin):
//   {"t":"start","token","fps","legacy","lanIP","audio","computer"}
//   {"t":"answer","data":<sdp>}   {"t":"ice","data":<candidate>}   {"t":"stop"}
// sidecar → Swift (stdout):
//   {"t":"offer","data":<sdp>}    {"t":"ice","data":<candidate>}
//   {"t":"state","ice":<s>}       {"t":"bwe","bps":<n>}
//   {"t":"ready"} (media socket connected)   {"t":"error","msg":<s>}

type ctrlMsg struct {
	T        string          `json:"t"`
	Token    string          `json:"token,omitempty"`
	FPS      int             `json:"fps,omitempty"`
	Legacy   bool            `json:"legacy,omitempty"`
	LanIP    string          `json:"lanIP,omitempty"`
	Audio    bool            `json:"audio,omitempty"`
	Computer string          `json:"computer,omitempty"`
	Level    float64         `json:"level,omitempty"`   // sink volume 0..1 ("volume")
	// Host-driven CASTv2 (§6.6): when castHost is set, the sidecar LAUNCHes the
	// receiver App ID itself and relays SDP/ICE over the Cast custom namespace —
	// no phone Cast SDK. Absent → phone-driven (offer/ice emitted on stdio).
	CastHost string          `json:"castHost,omitempty"`
	CastPort int             `json:"castPort,omitempty"`
	AppID    string          `json:"appID,omitempty"`
	// HLS mode (§6.5 Tier 3): mux the incoming H.264 to live HLS and LOAD it on
	// the Default Media Receiver instead of running WebRTC. Video-only for now.
	HLS  bool            `json:"hls,omitempty"`
	Data json.RawMessage `json:"data,omitempty"`
}

const castNamespace = "urn:x-cast:com.custavia.remotype.cast"

type session struct {
	out       *json.Encoder
	outMu     sync.Mutex
	listener  net.Listener
	pc        *webrtc.PeerConnection
	video     *webrtc.TrackLocalStaticSample
	audio     *webrtc.TrackLocalStaticSample
	opus      *opusEncoder
	pcmBuf    []int16
	fps       int
	lastVPTS  uint64
	haveVPTS  bool
	started   bool
	stopOnce  sync.Once
	done      chan struct{}
	// Host-driven CASTv2 signaling (§6.6).
	cast       *castV2
	hostDriven bool
	token      string
	computer   string
	// The offer is RESENT until the receiver answers. A real Cast device
	// allocates the app (LAUNCH returns) seconds before the receiver PAGE has
	// loaded and registered its custom-namespace listener; anything sent in that
	// window is dropped by the platform. The receiver cannot rescue a dropped
	// offer either — its send helper is gated on a senderId it only learns from
	// an INBOUND message, so a lost offer deadlocks the handshake permanently.
	answered    atomic.Bool
	offerLogged bool
	readyCh     chan struct{}
	audioIn     int
	audioOut    int
	audioWarned bool
	pliCount    int
	nackCount   int
	acceptedSeen atomic.Bool
	playingSeen  atomic.Bool
	playWatch    sync.Once
	readyOnce   sync.Once
	offerDone chan struct{}
	// HLS mode (§6.5 Tier 3).
	hls   *hlsPackager
	hlsLn net.Listener
}

func runSession(socketPath string) {
	s := &session{
		out:       json.NewEncoder(os.Stdout),
		fps:       24,
		done:      make(chan struct{}),
		offerDone: make(chan struct{}),
		readyCh:   make(chan struct{}),
	}
	// The media socket must not pre-exist; Swift passes a fresh per-session path.
	_ = os.Remove(socketPath)
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		s.emit(map[string]any{"t": "error", "msg": "media socket: " + err.Error()})
		os.Exit(1)
	}
	s.listener = ln
	defer os.Remove(socketPath)

	// Read control lines from stdin until EOF / stop.
	go s.readControl()
	<-s.done
}

func (s *session) emit(m map[string]any) {
	s.outMu.Lock()
	defer s.outMu.Unlock()
	_ = s.out.Encode(m) // Encode appends '\n'
}

func (s *session) readControl() {
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 0, 64*1024), 4<<20) // SDP blobs can exceed the default 64 KiB line cap
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var m ctrlMsg
		if err := json.Unmarshal(line, &m); err != nil {
			s.emit(map[string]any{"t": "error", "msg": "bad control json: " + err.Error()})
			continue
		}
		s.handle(m)
	}
	s.stop() // stdin closed → parent gone → tear down
}

func (s *session) handle(m ctrlMsg) {
	switch m.T {
	case "start":
		if s.started {
			return
		}
		s.started = true
		if m.FPS > 0 {
			s.fps = m.FPS
		}
		if err := s.start(m); err != nil {
			s.emit(map[string]any{"t": "error", "msg": err.Error()})
			s.stop()
		}
	case "answer":
		if s.pc == nil || len(m.Data) == 0 {
			return
		}
		var sd webrtc.SessionDescription
		if err := json.Unmarshal(m.Data, &sd); err != nil {
			s.emit(map[string]any{"t": "error", "msg": "answer parse: " + err.Error()})
			return
		}
		if err := s.pc.SetRemoteDescription(sd); err != nil {
			s.emit(map[string]any{"t": "error", "msg": "setRemote(answer): " + err.Error()})
		}
	case "ice":
		if s.pc == nil || len(m.Data) == 0 {
			return
		}
		var c webrtc.ICECandidateInit
		if err := json.Unmarshal(m.Data, &c); err != nil {
			return
		}
		_ = s.pc.AddICECandidate(c)
	case "volume":
		// The phone's TV-volume buttons. These were an accepted NO-OP on the
		// host ("the OS owns the mirror"), which was true for a native AirPlay
		// mirror but not for our own WebRTC session — so the buttons did
		// nothing. Drive the sink's real volume over CASTv2.
		if s.cast != nil {
			s.cast.setVolume(m.Level)
		}
	case "stop":
		s.stop()
	}
}

func (s *session) start(m ctrlMsg) error {
	if m.HLS {
		return s.startHLS(m)
	}
	// SettingEngine: advertise only LAN (RFC1918 IPv4) host candidates — never
	// Tailscale/CGNAT/utun/link-local/IPv6 (§14.1, §6.7).
	se := webrtc.SettingEngine{}
	se.SetIPFilter(func(ip net.IP) bool { return isPrivateLANv4(ip) })

	// MediaEngine + interceptors with send-side BWE (TWCC → GCC) for the §6.4 ladder.
	me := &webrtc.MediaEngine{}
	if err := registerCastCodecs(me); err != nil {
		return err
	}
	ir := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(me, ir); err != nil {
		return err
	}
	initialBitrate := 4_000_000
	if m.Legacy {
		initialBitrate = 2_500_000 // legacy Chromecast entry rung R3 (§6.5)
	}
	ccInt, err := cc.NewInterceptor(func() (cc.BandwidthEstimator, error) {
		return gcc.NewSendSideBWE(gcc.SendSideBWEInitialBitrate(initialBitrate))
	})
	if err != nil {
		return err
	}
	estCh := make(chan cc.BandwidthEstimator, 1)
	ccInt.OnNewPeerConnection(func(_ string, est cc.BandwidthEstimator) { estCh <- est })
	ir.Add(ccInt)
	if err := webrtc.ConfigureTWCCHeaderExtensionSender(me, ir); err != nil {
		return err
	}

	api := webrtc.NewAPI(webrtc.WithMediaEngine(me), webrtc.WithInterceptorRegistry(ir), webrtc.WithSettingEngine(se))
	pc, err := api.NewPeerConnection(webrtc.Configuration{}) // LAN: no STUN/TURN
	if err != nil {
		return err
	}
	s.pc = pc

	s.video, err = webrtc.NewTrackLocalStaticSample(
		webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH264}, "video", "remotype")
	if err != nil {
		return err
	}
	// SENDONLY, not AddTrack's implicit sendrecv: we only ever push media to the
	// TV, and a sendrecv m-line asks the receiver to send video back. A Cast
	// receiver has no camera and no media permission, so inviting it to answer
	// sendrecv is at best pointless and at worst why it never answers at all.
	vtr, err := pc.AddTransceiverFromTrack(s.video,
		webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionSendonly})
	if err != nil {
		return err
	}
	// Drain the receiver's RTCP for this track and count what it asks for. A
	// decoder that cannot handle the stream begs for keyframes (PLI) forever
	// while every other signal — ICE connected, bytes flowing, "casting" —
	// looks perfectly healthy. This is the only way to see that from here.
	if sender := vtr.Sender(); sender != nil {
		go func() {
			buf := make([]byte, 1500)
			for {
				n, _, rerr := sender.Read(buf)
				if rerr != nil {
					return
				}
				pkts, perr := rtcp.Unmarshal(buf[:n])
				if perr != nil {
					continue
				}
				for _, pkt := range pkts {
					switch pkt.(type) {
					case *rtcp.PictureLossIndication:
						s.pliCount++
						if s.pliCount == 1 || s.pliCount%10 == 0 {
							fmt.Fprintf(os.Stderr, "[cast] receiver PLI (keyframe requests): %d\n", s.pliCount)
						}
					case *rtcp.TransportLayerNack:
						s.nackCount++
						if s.nackCount%50 == 0 {
							fmt.Fprintf(os.Stderr, "[cast] receiver NACKs (lost packets): %d\n", s.nackCount)
						}
					}
				}
			}
		}()
	}
	if m.Audio {
		s.audio, err = webrtc.NewTrackLocalStaticSample(
			webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus}, "audio", "remotype")
		if err != nil {
			return err
		}
		if _, err = pc.AddTransceiverFromTrack(s.audio,
			webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionSendonly}); err != nil {
			return err
		}
		if s.opus, err = newOpusEncoder(); err != nil {
			return err
		}
	}

	s.token = m.Token
	s.computer = m.Computer
	s.hostDriven = m.CastHost != ""

	// Local ICE: phone-driven trickles over stdio; host-driven is non-trickle
	// (all candidates ride in the offer SDP), so we forward nothing here.
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c == nil || s.hostDriven {
			return
		}
		s.emit(map[string]any{"t": "ice", "data": c.ToJSON()})
	})
	pc.OnICEConnectionStateChange(func(st webrtc.ICEConnectionState) {
		s.emit(map[string]any{"t": "state", "ice": st.String()})
		if st == webrtc.ICEConnectionStateFailed || st == webrtc.ICEConnectionStateClosed {
			s.stop()
		}
	})

	offer, err := pc.CreateOffer(nil)
	if err != nil {
		return err
	}
	gatherComplete := webrtc.GatheringCompletePromise(pc)
	if err := pc.SetLocalDescription(offer); err != nil {
		return err
	}

	if s.hostDriven {
		go s.runHostDriven(m, gatherComplete)
	} else {
		s.emit(map[string]any{"t": "offer", "data": pc.LocalDescription()})
	}

	go s.reportBWE(estCh)
	go s.acceptMedia()
	return nil
}

// runHostDriven opens the host's own CASTv2 connection, LAUNCHes the receiver App
// ID, and relays SDP/ICE over the custom namespace — the phone is not involved.
func (s *session) runHostDriven(m ctrlMsg, gatherComplete <-chan struct{}) {
	<-gatherComplete // non-trickle: the offer SDP now carries every LAN candidate
	port := m.CastPort
	if port == 0 {
		port = 8009
	}
	s.cast = newCastV2(m.AppID, castNamespace, s.onReceiverMsg)
	// A connect/LAUNCH failure means the host can't reach this TV from where it is
	// (remote PC, different LAN) — NOT a hard error: it's the pivot to the phone
	// taking over the cast (Tier 2/3). Emit a distinct "reachfail" the host maps to
	// a phone-takeover signal.
	if err := s.cast.connect(m.CastHost, port); err != nil {
		s.emit(map[string]any{"t": "reachfail", "msg": "connect"})
		s.stop()
		return
	}
	// 8 s: a real receiver launches in ~2-4 s (fetch URL + CAF + start()); a longer
	// wait just delays the automatic HLS fallback when the custom receiver can't
	// launch (unpublished / not yet propagated to this device).
	if err := s.cast.launch(8 * time.Second); err != nil {
		s.emit(map[string]any{"t": "reachfail", "msg": "launch"})
		s.stop()
		return
	}
	// The receiver announces {kind:"ready"} once its listener is up, which sends
	// the offer immediately. RESEND on a cadence regardless: `ready` itself can be
	// lost (the receiver only learns our senderId from an inbound message), and a
	// single blind send races the page load.
	go s.offerLoop()
}

// offerLoop delivers the offer once the receiver is known to be listening, and
// only re-sends if that attempt is ignored entirely.
//
// Cadence matters more than it looks: every offer makes the receiver TEAR DOWN
// and rebuild its peer connection, so an eager resend invalidates a negotiation
// that was already succeeding — the first answer gets accepted, the resend's
// answer is rejected ("stable->SetRemote(answer)->stable"), and the receiver
// then trickles candidates for the rebuilt connection that we drop for a ufrag
// mismatch. ICE starves and the cast dies with everything apparently working.
func (s *session) offerLoop() {
	const (
		noReadyFallback = 2 * time.Second  // older receivers never announce "ready"
		resendAfter     = 12 * time.Second // only if the offer was ignored outright
		deadline        = 45 * time.Second
	)
	select {
	case <-s.done:
		return
	case <-s.offerDone:
		return
	case <-s.readyCh:
	case <-time.After(noReadyFallback):
	}
	s.sendOffer()

	resend := time.NewTicker(resendAfter)
	defer resend.Stop()
	giveUp := time.After(deadline)
	for {
		select {
		case <-s.done:
			return
		case <-s.offerDone:
			return
		case <-giveUp:
			if !s.answered.Load() {
				fmt.Fprintf(os.Stderr, "[cast] no answer within %s — giving up\n", deadline)
				s.emit(map[string]any{"t": "reachfail", "msg": "noanswer"})
				s.stop()
			}
			return
		case <-resend.C:
			if s.answered.Load() {
				return
			}
			fmt.Fprintf(os.Stderr, "[cast] no answer yet — re-sending offer\n")
			s.sendOffer()
		}
	}
}

// ensureAudible raises a sink that is sitting at zero output. A Chromecast at
// level 0.0 decodes our Opus perfectly and plays it into silence, which reads
// as "cast audio is broken" — so casting WITH audio nudges it to something
// hearable once, and never touches a level the user has actually set.
func (s *session) ensureAudible() {
	if s.cast == nil {
		return
	}
	if lvl := s.cast.volumeLevel(); lvl <= 0.001 {
		fmt.Fprintf(os.Stderr, "[cast] sink volume is %.2f — raising to 0.4 so audio is audible\n", lvl)
		s.cast.setVolume(0.4)
	}
}

// sendOffer delivers the complete (non-trickle) offer over the Cast custom
// namespace. Safe to call repeatedly: the receiver pins our token on the first
// one it actually receives and ignores duplicates of the same token.
func (s *session) sendOffer() {
	if s.pc == nil || s.cast == nil || s.answered.Load() {
		return
	}
	desc := s.pc.LocalDescription()
	if !s.offerLogged {
		s.offerLogged = true
		fmt.Fprintf(os.Stderr, "[cast] OFFER SDP >>>\n%s\n<<< END OFFER\n", desc.SDP)
	}
	if err := s.cast.sendCustom(map[string]any{
		"kind": "offer", "token": s.token, "computer": s.computer,
		"data": desc}); err != nil {
		fmt.Fprintf(os.Stderr, "[cast] offer send failed: %v\n", err)
	}
}

// onReceiverMsg handles custom-namespace messages from the receiver (host-driven).
func (s *session) onReceiverMsg(obj map[string]any) {
	kind, _ := obj["kind"].(string)
	// §14.2 token pin: once we've shared a token, answers/ICE must echo it.
	if tok, ok := obj["token"].(string); ok && s.token != "" && tok != s.token {
		return
	}
	switch kind {
	case "ready":
		// Unblock offerLoop rather than sending here: one sender, one offer.
		s.readyOnce.Do(func() { close(s.readyCh) })
	case "audible":
		s.ensureAudible()
	case "playing":
		s.playingSeen.Store(true)
		fmt.Fprintf(os.Stderr, "[cast] RECEIVER IS RENDERING: %v\n", obj["info"])
	case "icestate":
		fmt.Fprintf(os.Stderr, "[cast] receiver ICE: %v\n", obj["state"])
	case "accepted":
		s.acceptedSeen.Store(true)
		fmt.Fprintf(os.Stderr, "[cast] receiver accepted the offer, building peer connection\n")
	case "error":
		// The receiver told us exactly which step failed — the single most useful
		// signal we have, since the TV has no reachable console.
		stage, _ := obj["stage"].(string)
		msg, _ := obj["message"].(string)
		fmt.Fprintf(os.Stderr, "[cast] RECEIVER ERROR at %s: %s\n", stage, msg)
	case "answer":
		if data, ok := obj["data"].(map[string]any); ok {
			if sdp, ok := data["sdp"].(string); ok {
				if err := s.pc.SetRemoteDescription(webrtc.SessionDescription{
					Type: webrtc.SDPTypeAnswer, SDP: sdp}); err != nil {
					fmt.Fprintf(os.Stderr, "[cast] bad answer SDP: %v\n", err)
					return
				}
				var mlines []string
				for _, l := range strings.Split(sdp, "\n") {
					l = strings.TrimSpace(l)
					if strings.HasPrefix(l, "m=") || l == "a=recvonly" || l == "a=inactive" {
						mlines = append(mlines, l)
					}
				}
				fmt.Fprintf(os.Stderr, "[cast] ANSWER accepted: %s\n", strings.Join(mlines, " | "))
				if s.answered.CompareAndSwap(false, true) {
					close(s.offerDone)
					if s.audio != nil {
						s.ensureAudible()
					}
				}
			}
		}
	case "ice":
		if data, ok := obj["data"].(map[string]any); ok {
			init := webrtc.ICECandidateInit{}
			if c, ok := data["candidate"].(string); ok {
				init.Candidate = c
			}
			if mid, ok := data["sdpMid"].(string); ok {
				init.SDPMid = &mid
			}
			if idx, ok := data["sdpMLineIndex"].(float64); ok {
				u := uint16(idx)
				init.SDPMLineIndex = &u
			}
			_ = s.pc.AddICECandidate(init)
		}
	}
}

// acceptMedia takes the single media connection from the Swift host and pumps
// frames into the tracks (WebRTC) or the HLS packager until EOF.
func (s *session) acceptMedia() {
	conn, err := s.listener.Accept()
	if err != nil {
		return
	}
	s.emit(map[string]any{"t": "ready"})
	r := bufio.NewReaderSize(conn, 1<<20)
	for {
		f, err := readFrame(r)
		if err != nil {
			return
		}
		switch f.kind {
		case kindVideo:
			if s.hls != nil {
				s.hls.writeVideo(f.payload, f.ptsUS, isKeyframeAnnexB(f.payload))
			} else {
				s.writeVideo(f)
			}
		case kindAudio:
			if s.hls == nil { // PCM → Opus for the WebRTC path
				s.writeAudio(f.payload)
			}
		case kindAudioAAC:
			if s.hls != nil { // real computer audio for the HLS mux
				s.hls.pushAAC(f.payload)
			}
		}
	}
}

// startHLS runs the §6.5 Tier-3 path: mux the incoming H.264 to a live HLS stream
// served on the LAN, LAUNCH the Default Media Receiver, and LOAD the playlist.
func (s *session) startHLS(m ctrlMsg) error {
	s.hls = newHLSPackager()
	mux := http.NewServeMux()
	s.hls.register(mux)
	ln, err := net.Listen("tcp", ":0")
	if err != nil {
		return err
	}
	s.hlsLn = ln
	port := ln.Addr().(*net.TCPAddr).Port
	go func() { _ = http.Serve(ln, mux) }()
	lanIP := m.LanIP
	if lanIP == "" {
		lanIP = primaryLANIP()
	}
	url := fmt.Sprintf("http://%s:%d/live.m3u8", lanIP, port)
	fmt.Fprintf(os.Stderr, "[hls] serving %s\n", url)
	go s.acceptMedia()
	go s.runHLSCast(m, url)
	return nil
}

func (s *session) runHLSCast(m ctrlMsg, url string) {
	port := m.CastPort
	if port == 0 {
		port = 8009
	}
	appID := m.AppID
	if appID == "" {
		appID = "CC1AD845" // Default Media Receiver — plays HLS, no App ID needed
	}
	// Connect + LAUNCH with one retry: a TCP-connect failure means the host truly
	// can't reach the TV (→ reachfail, phone takeover); a LAUNCH that connects but
	// times out is a transient receiver hiccup, so try a fresh connection once.
	var launched bool
	for attempt := 0; attempt < 3 && !launched; attempt++ {
		c := newCastV2(appID, castNamespace, nil)
		if err := c.connect(m.CastHost, port); err != nil {
			c.stop()
			time.Sleep(700 * time.Millisecond)
			continue
		}
		if err := c.launch(10 * time.Second); err != nil {
			c.stop()
			time.Sleep(700 * time.Millisecond)
			continue
		}
		s.cast = c
		launched = true
	}
	if !launched {
		// Report the pivot to phone-driven, but DON'T tear down — the host decides
		// (a transient sink hiccup shouldn't kill the whole media pipeline).
		s.emit(map[string]any{"t": "reachfail", "msg": "launch"})
		return
	}
	// LAUNCHed → tell Swift to start capture so the packager gets frames.
	s.emit(map[string]any{"t": "state", "ice": "connected"})
	// Wait for a couple of buffered segments, then LOAD the live playlist.
	for i := 0; i < 200; i++ {
		select {
		case <-s.done:
			return
		default:
		}
		if s.hls.ready() {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	title := m.Computer
	if title == "" {
		title = "Remotype"
	}
	_ = s.cast.load(url, "application/vnd.apple.mpegurl", "LIVE", title)
	// Poll the receiver's media status so we SEE whether it actually plays our
	// stream (PLAYING) or rejects it (IDLE + idleReason=ERROR).
	go func() {
		for i := 0; i < 30; i++ {
			select {
			case <-s.done:
				return
			case <-time.After(2 * time.Second):
			}
			s.cast.mediaGetStatus()
		}
	}()
}

// isKeyframeAnnexB reports whether an Annex-B access unit contains an IDR NAL
// (type 5). Our encoder emits 4-byte start codes, so scan for 00 00 00 01 + type.
func isKeyframeAnnexB(data []byte) bool {
	for i := 0; i+5 <= len(data); i++ {
		if data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && data[i+3] == 1 {
			if data[i+4]&0x1F == 5 {
				return true
			}
		}
	}
	return false
}

func (s *session) writeVideo(f mediaFrame) {
	if s.video == nil {
		return
	}
	// Duration drives the RTP timestamp; use real PTS deltas so the media clock
	// tracks capture time and A/V stays in sync (§6.3).
	dur := time.Second / time.Duration(s.fps)
	if s.haveVPTS && f.ptsUS > s.lastVPTS {
		dur = time.Duration(f.ptsUS-s.lastVPTS) * time.Microsecond
	}
	s.lastVPTS = f.ptsUS
	s.haveVPTS = true
	_ = s.video.WriteSample(media.Sample{Data: f.payload, Duration: dur})
}

func (s *session) writeAudio(payload []byte) {
	if s.audio == nil || s.opus == nil {
		if !s.audioWarned {
			s.audioWarned = true
			fmt.Fprintf(os.Stderr, "[cast] AUDIO DROPPED: track=%v opus=%v\n", s.audio != nil, s.opus != nil)
		}
		return
	}
	s.audioIn++
	if s.audioIn == 1 {
		fmt.Fprintf(os.Stderr, "[cast] first audio frame from host (%d bytes)\n", len(payload))
	}
	// payload = interleaved stereo Int16 LE. Accumulate and emit exact 20 ms frames.
	n := len(payload) / 2
	for i := 0; i < n; i++ {
		s.pcmBuf = append(s.pcmBuf, int16(payload[2*i])|int16(payload[2*i+1])<<8)
	}
	frame := opusFrameSamples * opusChannels
	for len(s.pcmBuf) >= frame {
		pkt, err := s.opus.encode(s.pcmBuf[:frame])
		s.pcmBuf = s.pcmBuf[frame:]
		if err != nil {
			continue
		}
		s.audioOut++
		if s.audioOut == 1 || s.audioOut%250 == 0 {
			fmt.Fprintf(os.Stderr, "[cast] opus packets sent: %d\n", s.audioOut)
		}
		_ = s.audio.WriteSample(media.Sample{Data: pkt, Duration: opusFrameMS * time.Millisecond})
	}
}

// reportBWE forwards the GCC target bitrate to Swift once a second so the host
// can move the VTCompressionSession up/down the §6.4 rung ladder.
func (s *session) reportBWE(estCh chan cc.BandwidthEstimator) {
	var est cc.BandwidthEstimator
	select {
	case est = <-estCh:
	case <-time.After(5 * time.Second):
		return
	}
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-s.done:
			return
		case <-t.C:
			s.emit(map[string]any{"t": "bwe", "bps": est.GetTargetBitrate()})
		}
	}
}

func (s *session) stop() {
	s.stopOnce.Do(func() {
		if s.cast != nil {
			s.cast.stop()
		}
		if s.pc != nil {
			_ = s.pc.Close()
		}
		if s.opus != nil {
			s.opus.close()
		}
		if s.listener != nil {
			_ = s.listener.Close()
		}
		if s.hlsLn != nil {
			_ = s.hlsLn.Close()
		}
		close(s.done)
	})
}

func registerCastCodecs(m *webrtc.MediaEngine) error {
	if err := m.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeH264,
			ClockRate:   90000,
			SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
		},
		PayloadType: 102,
	}, webrtc.RTPCodecTypeVideo); err != nil {
		return err
	}
	return m.RegisterCodec(webrtc.RTPCodecParameters{
		RTPCodecCapability: webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeOpus,
			ClockRate:   48000,
			Channels:    2,
			SDPFmtpLine: "minptime=10;useinbandfec=1;stereo=1",
		},
		PayloadType: 111,
	}, webrtc.RTPCodecTypeAudio)
}

// isPrivateLANv4 keeps only RFC1918 IPv4 (10/8, 172.16/12, 192.168/16), dropping
// CGNAT/Tailscale (100.64/10), link-local, loopback, public, and all IPv6 — a
// Chromecast on a home LAN is always reachable on a private IPv4.
func isPrivateLANv4(ip net.IP) bool {
	v4 := ip.To4()
	if v4 == nil {
		return false
	}
	switch {
	case v4[0] == 10:
		return true
	case v4[0] == 172 && v4[1] >= 16 && v4[1] <= 31:
		return true
	case v4[0] == 192 && v4[1] == 168:
		return true
	}
	return false
}
