package main

// Minimal CASTv2 sender for the Cast DIRECT host-driven path. The Mac host owns
// its own connection to the sink (docs/CASTING.md §6.6): it LAUNCHes the custom
// receiver App ID, opens our custom namespace, and relays WebRTC SDP/ICE straight
// to the receiver — so the phone needs no Cast SDK (it only picks the target the
// host already discovered via mDNS and sends cast.start). Also carries PING
// keepalive (§10.5), SET_VOLUME (§8.6), and STOP (§10.6).
//
// Built on vishen/go-chromecast's low-level cast.Connection (TLS framing +
// protobuf CastMessage + auto-PONG); the LAUNCH/status/relay logic is ours.

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"

	castnet "github.com/vishen/go-chromecast/cast"
)

const (
	nsConnection = "urn:x-cast:com.google.cast.tp.connection"
	nsReceiver   = "urn:x-cast:com.google.cast.receiver"
	nsMedia      = "urn:x-cast:com.google.cast.media"
	srcSender    = "sender-0"
	dstReceiver  = "receiver-0"
)

// rawPayload lets us send arbitrary JSON (our {kind,token,data} envelope) through
// cast.Connection.Send, which json.Marshals the Payload.
type rawPayload struct{ b []byte }

func (rawPayload) SetRequestId(int)              {}
func (r rawPayload) MarshalJSON() ([]byte, error) { return r.b, nil }

type castV2 struct {
	conn        *castnet.Connection
	appID       string
	namespace   string
	transportID string
	sessionID   string
	reqID       int
	connected   bool
	lastVolume  float64
	mu          sync.Mutex
	onCustom    func(map[string]any)
	launched    chan struct{}
	stopOnce    sync.Once
	done        chan struct{}
}

func newCastV2(appID, namespace string, onCustom func(map[string]any)) *castV2 {
	return &castV2{
		conn:      castnet.NewConnection(),
		appID:     appID,
		namespace: namespace,
		onCustom:  onCustom,
		launched:  make(chan struct{}),
		done:      make(chan struct{}),
	}
}

func (c *castV2) nextReq() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.reqID++
	return c.reqID
}

// connect opens the transport, establishes the receiver-0 virtual connection, and
// starts the receive loop.
func (c *castV2) connect(host string, port int) error {
	if err := c.conn.Start(host, port); err != nil {
		return err
	}
	c.connected = true
	go c.receiveLoop()
	return c.send(dstReceiver, nsConnection, &castnet.PayloadHeader{Type: "CONNECT"})
}

// launch requests the receiver app and blocks until it reports a transportId (or
// times out). On success we open a virtual connection to the app so custom-
// namespace messages reach it.
func (c *castV2) launch(timeout time.Duration) error {
	if err := c.send(dstReceiver, nsReceiver,
		&castnet.LaunchRequest{PayloadHeader: castnet.PayloadHeader{Type: "LAUNCH", RequestId: c.nextReq()}, AppId: c.appID}); err != nil {
		return err
	}
	select {
	case <-c.launched:
		return c.send(c.transportID, nsConnection, &castnet.PayloadHeader{Type: "CONNECT"})
	case <-time.After(timeout):
		return fmt.Errorf("cast LAUNCH timed out")
	case <-c.done:
		return fmt.Errorf("cast connection closed")
	}
}

// sendCustom relays one JSON message to the receiver on our custom namespace.
func (c *castV2) sendCustom(obj map[string]any) error {
	if c.transportID == "" {
		return fmt.Errorf("no receiver session")
	}
	b, err := json.Marshal(obj)
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "[cast->] ns=%s dst=%s len=%d\n", c.namespace, c.transportID, len(b))
	return c.send(c.transportID, c.namespace, rawPayload{b: b})
}

// load LOADs a media URL onto the receiver (Tier 3 HLS bridge). streamType is
// "LIVE" for a live HLS or "BUFFERED" for VOD.
func (c *castV2) load(url, contentType, streamType, title string) error {
	if c.transportID == "" {
		return fmt.Errorf("no receiver session")
	}
	payload := fmt.Sprintf(
		`{"type":"LOAD","requestId":%d,"autoplay":true,"currentTime":0,"media":{"contentId":%q,"streamType":%q,"contentType":%q,"metadata":{"metadataType":0,"title":%q}}}`,
		c.nextReq(), url, streamType, contentType, title)
	return c.send(c.transportID, nsMedia, rawPayload{b: []byte(payload)})
}

// mediaGetStatus asks the receiver for the current MEDIA_STATUS (playerState).
func (c *castV2) mediaGetStatus() {
	if c.transportID == "" {
		return
	}
	_ = c.send(c.transportID, nsMedia, rawPayload{b: []byte(
		fmt.Sprintf(`{"type":"GET_STATUS","requestId":%d}`, c.nextReq()))})
}

// lastVolume is the sink's own output level from RECEIVER_STATUS. A Chromecast
// sitting at 0.0 plays a perfect Opus stream into silence, which is exactly how
// "cast audio does nothing" looked.
func (c *castV2) volumeLevel() float64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lastVolume
}

func (c *castV2) setVolume(level float64) {
	_ = c.send(dstReceiver, nsReceiver, rawPayload{b: []byte(
		fmt.Sprintf(`{"type":"SET_VOLUME","requestId":%d,"volume":{"level":%f}}`, c.nextReq(), level))})
}

func (c *castV2) send(dst, namespace string, payload castnet.Payload) error {
	return c.conn.Send(0, payload, srcSender, dst, namespace)
}

func (c *castV2) receiveLoop() {
	for {
		select {
		case <-c.done:
			return
		case msg := <-c.conn.MsgChan():
			if msg == nil || msg.PayloadUtf8 == nil {
				continue
			}
			ns := msg.GetNamespace()
			payload := *msg.PayloadUtf8
			// RCA instrumentation: log EVERY inbound frame so a silent hang in the
			// custom-namespace handshake is visible.
			if len(payload) > 400 {
				fmt.Fprintf(os.Stderr, "[cast<-] ns=%s len=%d %s…\n", ns, len(payload), payload[:400])
			} else {
				fmt.Fprintf(os.Stderr, "[cast<-] ns=%s %s\n", ns, payload)
			}
			switch ns {
			case nsReceiver:
				c.handleReceiverStatus(payload)
			case c.namespace:
				var obj map[string]any
				if json.Unmarshal([]byte(payload), &obj) == nil && c.onCustom != nil {
					c.onCustom(obj)
				}
			case nsMedia:
				// Log the FULL payload — playerState, idleReason, and any error the
				// receiver reports when it can't decode/play our stream.
				fmt.Fprintf(os.Stderr, "[media] %s\n", payload)
			}
		}
	}
}

type receiverStatus struct {
	Type   string `json:"type"`
	Status struct {
		Volume struct {
			Level float64 `json:"level"`
			Muted bool    `json:"muted"`
		} `json:"volume"`
		Applications []struct {
			AppID       string `json:"appId"`
			TransportID string `json:"transportId"`
			SessionID   string `json:"sessionId"`
			StatusText  string `json:"statusText"`
		} `json:"applications"`
	} `json:"status"`
}

func (c *castV2) handleReceiverStatus(payload string) {
	var st receiverStatus
	if json.Unmarshal([]byte(payload), &st) == nil && st.Type == "RECEIVER_STATUS" {
		c.mu.Lock()
		c.lastVolume = st.Status.Volume.Level
		c.mu.Unlock()
	}
	if json.Unmarshal([]byte(payload), &st) != nil || st.Type != "RECEIVER_STATUS" {
		// A rejected LAUNCH comes back as LAUNCH_ERROR on this namespace (with a
		// reason like NOT_ALLOWED / NOT_FOUND / SYSTEM_ERROR). Without this the
		// device's real reason was dropped and we only saw an opaque timeout.
		if st.Type == "LAUNCH_ERROR" {
			fmt.Fprintf(os.Stderr, "[cast] LAUNCH_ERROR from sink: %s\n", payload)
		}
		return
	}
	for _, app := range st.Status.Applications {
		if app.AppID == c.appID && app.TransportID != "" {
			first := c.transportID == ""
			c.transportID = app.TransportID
			c.sessionID = app.SessionID
			if first {
				close(c.launched)
			}
			return
		}
	}
}

func (c *castV2) stop() {
	c.stopOnce.Do(func() {
		// If we never actually connected (e.g. reach failed before connect()), the
		// underlying socket is nil — sending STOP would panic in cast.Connection.Send.
		// Nothing was ever LAUNCHed, so there's nothing to STOP; just tear down.
		if !c.connected {
			close(c.done)
			return
		}
		// STOP the receiver app so the sink clears (returns to its ambient screen)
		// instead of freezing on the last frame — and so the session is released so
		// the NEXT cast can LAUNCH. Fall back to a session-less STOP if we somehow
		// never captured the sessionId.
		if c.sessionID != "" {
			_ = c.send(dstReceiver, nsReceiver, rawPayload{b: []byte(
				fmt.Sprintf(`{"type":"STOP","requestId":%d,"sessionId":%q}`, c.nextReq(), c.sessionID))})
		} else {
			_ = c.send(dstReceiver, nsReceiver, rawPayload{b: []byte(
				fmt.Sprintf(`{"type":"STOP","requestId":%d}`, c.nextReq()))})
		}
		// Let the STOP actually transmit before tearing the socket down — closing
		// immediately dropped it, leaving the receiver running (the stuck-CC bug).
		time.Sleep(350 * time.Millisecond)
		close(c.done)
		_ = c.conn.Close()
	})
}

// runCastStatus prints which app the sink is running — used to verify a cast
// actually stopped. `remotype-cast-helper --caststatus <ip>`.
// runCastStop tears down whatever app the sink is running — the clean-slate
// button for testing (a resident receiver otherwise joins the next session with
// stale page code and stale state).
func runCastStop(host string) {
	c := newCastV2("", "", nil)
	if err := c.conn.Start(host, 8009); err != nil {
		fmt.Fprintf(os.Stderr, "connect: %v\n", err)
		return
	}
	_ = c.send(dstReceiver, nsConnection, &castnet.PayloadHeader{Type: "CONNECT"})
	_ = c.send(dstReceiver, nsReceiver, rawPayload{b: []byte(
		fmt.Sprintf(`{"type":"STOP","requestId":%d}`, c.nextReq()))})
	time.Sleep(600 * time.Millisecond)
	fmt.Println("STOP sent")
}

func runCastStatus(host string) {
	done := make(chan string, 1)
	c := newCastV2("", "", nil)
	c.conn.Start(host, 8009)
	go func() {
		for {
			select {
			case <-c.done:
				return
			case msg := <-c.conn.MsgChan():
				if msg != nil && msg.PayloadUtf8 != nil && msg.GetNamespace() == nsReceiver {
					var st receiverStatus
					if json.Unmarshal([]byte(*msg.PayloadUtf8), &st) == nil && st.Type == "RECEIVER_STATUS" {
						apps := ""
						for _, a := range st.Status.Applications {
							apps += fmt.Sprintf("%s(%s) ", a.AppID, a.StatusText)
						}
						if apps == "" {
							apps = "<none — idle>"
						}
						select {
						case done <- apps:
						default:
						}
					}
				}
			}
		}
	}()
	_ = c.send(dstReceiver, nsConnection, &castnet.PayloadHeader{Type: "CONNECT"})
	_ = c.send(dstReceiver, nsReceiver, &castnet.PayloadHeader{Type: "GET_STATUS", RequestId: 1})
	select {
	case apps := <-done:
		fmt.Println("running app:", apps)
	case <-time.After(5 * time.Second):
		fmt.Println("no status")
	}
	_ = c.conn.Close() // just disconnect — do NOT send STOP (we're only observing)
}

// runCastProbe is a standalone live check: connect → LAUNCH → print the running
// app. `remotype-cast-helper --castprobe <ip> <appId>` — validates the CASTv2
// sender against a real device with no WebRTC/phone involved.
func runCastProbe(host, appID string) {
	c := newCastV2(appID, "urn:x-cast:com.custavia.remotype.cast", func(obj map[string]any) {
		fmt.Fprintf(os.Stderr, "[probe] custom msg: %v\n", obj)
	})
	if err := c.connect(host, 8009); err != nil {
		fmt.Println("FAIL connect:", err)
		os.Exit(1)
	}
	fmt.Fprintln(os.Stderr, "[probe] connected, launching", appID)
	if err := c.launch(10 * time.Second); err != nil {
		fmt.Println("FAIL launch:", err)
		os.Exit(1)
	}
	fmt.Printf("PASS: launched %s → transportId=%s sessionId=%s\n", appID, c.transportID, c.sessionID)
	time.Sleep(2 * time.Second)
	c.stop()
}

// runCastLoad de-risks Tier 3: LAUNCH the Default Media Receiver and LOAD an HLS
// URL, printing MEDIA_STATUS so we can see whether the (legacy) device plays it.
func runCastLoad(host, url, streamType string) {
	c := newCastV2("CC1AD845", castNamespace, nil)
	if err := c.connect(host, 8009); err != nil {
		fmt.Println("FAIL connect:", err)
		os.Exit(1)
	}
	if err := c.launch(10 * time.Second); err != nil {
		fmt.Println("FAIL launch:", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "[probe] launched, LOADing %s\n", url)
	if err := c.load(url, "application/x-mpegurl", streamType, "Remotype test"); err != nil {
		fmt.Println("FAIL load:", err)
		os.Exit(1)
	}
	time.Sleep(12 * time.Second) // watch MEDIA_STATUS transitions
	c.stop()
}
