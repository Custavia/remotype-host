// Cast-target discovery (docs/CASTING.md §5): while any phone holds a cast.scan.sub,
// the host browses _googlecast._tcp + _airplay._tcp in short cycles and streams
// full cast.targets snapshots to every subscribed connection. Process-global,
// like the overlay: subscriptions come and go per connection, the scanner and
// its target cache are shared. This file is portable (pure zeroconf + net) —
// the Miracast capability gate and the cast session live in cast_windows.go
// (stubs in cast_stub.go).
package main

import (
	"context"
	"encoding/json"
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/grandcat/zeroconf"
)

// Scan cadence: a fresh Browse per cycle, because the zeroconf client delivers
// each instance at most once per resolver (sentEntries in client.go) and stops
// re-querying after the first hit — re-browsing is the only way to refresh
// lastSeen. Eviction after 10 s of absence is the §5.2 hysteresis window
// (two missed cycles).
const (
	castBrowseWindow = 4 * time.Second
	castCycleGap     = 1 * time.Second
	castStaleAfter   = 10 * time.Second
	castProbeTimeout = 1500 * time.Millisecond
)

// The one synthetic Miracast target (§2.1: no addr/port — it is a host
// capability, not a LAN endpoint). Real sink names need WinRT enumeration,
// which is a later slice.
const (
	miracastTargetId   = "miracast:wink"
	miracastTargetName = "Wireless display (Win+K)"
)

// castTarget is one discovered sink (§5.4 target object).
type castTarget struct {
	id       string
	name     string
	typ      string // "cast" | "airplay" (miracast is synthesized per snapshot)
	addr     string
	port     int
	model    string
	deviceId string
	present  bool      // seen in the most recent browse cycle
	lastSeen time.Time // when present flipped (sighting, or the loss transition)
}

type castScanner struct {
	mu      sync.Mutex // guards subs/targets/stop
	subs    map[*connState]struct{}
	targets map[string]*castTarget
	stop    chan struct{} // non-nil while the browse loop runs

	emitMu   sync.Mutex // serializes snapshot emits; guards lastSent
	lastSent string     // JSON of the last emitted snapshot (change detection)
}

var castScan = &castScanner{
	subs:    map[*connState]struct{}{},
	targets: map[string]*castTarget{},
}

// startCastScan subscribes this connection to cast.targets snapshots (mirrors
// the vitals sub/unsub shape). The first full snapshot — empty list included —
// is sent immediately, satisfying the ≤2 s acknowledgment contract (§8.1).
func (cs *connState) startCastScan() {
	if cs.castScanSubscribed {
		cs.send(castScan.snapshot()) // duplicate sub: just re-answer
		return
	}
	cs.castScanSubscribed = true
	castScan.subscribe(cs)
}

func (cs *connState) stopCastScan() {
	if !cs.castScanSubscribed {
		return
	}
	cs.castScanSubscribed = false
	castScan.unsubscribe(cs)
}

func (s *castScanner) subscribe(cs *connState) {
	s.mu.Lock()
	s.subs[cs] = struct{}{}
	first := len(s.subs) == 1
	if first {
		s.stop = make(chan struct{})
		go s.loop(s.stop)
	}
	s.mu.Unlock()
	if first {
		castScanHook(true)
	}
	cs.send(s.snapshot())
}

func (s *castScanner) unsubscribe(cs *connState) {
	s.mu.Lock()
	delete(s.subs, cs)
	last := len(s.subs) == 0 && s.stop != nil
	if last {
		close(s.stop)
		s.stop = nil
		s.targets = map[string]*castTarget{} // next subscriber starts fresh
	}
	s.mu.Unlock()
	if last {
		s.emitMu.Lock()
		s.lastSent = ""
		s.emitMu.Unlock()
		castScanHook(false)
	}
}

// refresh re-emits the snapshot if it changed — used by the platform layer
// when the Miracast capability verdict flips.
func (s *castScanner) refresh() { s.emitIfChanged() }

// loop runs browse cycles while at least one subscription is held; a 1 s side
// ticker keeps stale eviction close to the 10 s hysteresis even mid-cycle.
func (s *castScanner) loop(stop chan struct{}) {
	go func() {
		t := time.NewTicker(time.Second)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				if s.evictStale() {
					s.emitIfChanged()
				}
			}
		}
	}()
	for {
		cycleStart := time.Now()
		s.cycle(stop)
		if s.markAbsent(cycleStart) {
			s.emitIfChanged()
		}
		select {
		case <-stop:
			return
		case <-time.After(castCycleGap):
		}
	}
}

// markAbsent flips any target not refreshed during the just-finished cycle to
// stale (§5.2/§5.4): present=false starts a fresh 10 s eviction clock and the
// next snapshot carries "stale":true, so the phone grays+disables the row for
// the hysteresis window before evictStale removes it. Mirrors the Mac host's
// present-flag model (CastDiscovery: a browse-result drop keeps the entry for
// staleEviction with present=false).
func (s *castScanner) markAbsent(cycleStart time.Time) (changed bool) {
	now := time.Now()
	s.mu.Lock()
	for _, t := range s.targets {
		if t.present && t.lastSeen.Before(cycleStart) {
			t.present = false
			t.lastSeen = now
			changed = true
		}
	}
	s.mu.Unlock()
	return changed
}

// cycle browses both service types concurrently for one window. Each service
// gets its own resolver: two Browses on one resolver would race for packets
// (each spawns its own recv readers on the shared sockets).
func (s *castScanner) cycle(stop chan struct{}) {
	ctx, cancel := context.WithTimeout(context.Background(), castBrowseWindow)
	defer cancel()
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-stop:
			cancel()
		case <-done:
		}
	}()

	var wg sync.WaitGroup
	for _, svc := range []string{"_googlecast._tcp", "_airplay._tcp"} {
		wg.Add(1)
		go func(svc string) {
			defer wg.Done()
			s.browseOnce(ctx, svc)
		}(svc)
	}
	wg.Wait()
}

func (s *castScanner) browseOnce(ctx context.Context, svc string) {
	r, err := zeroconf.NewResolver(nil)
	if err != nil {
		logf("cast browse resolver failed: %v", err)
		return
	}
	entries := make(chan *zeroconf.ServiceEntry, 8)
	if err := r.Browse(ctx, svc, "local.", entries); err != nil {
		logf("cast browse failed: %v", err)
		return
	}
	for e := range entries { // closed by the resolver when ctx expires
		s.upsert(svc, e)
	}
}

// upsert records/refreshes one mDNS result. Dedup key (§5.3): the sink's own
// device id (cast TXT `id`, airplay TXT `deviceid`) when present, else
// IP+type — so an IP change keeps the sink's identity.
func (s *castScanner) upsert(svc string, e *zeroconf.ServiceEntry) {
	typ := "cast"
	if strings.HasPrefix(svc, "_airplay") {
		typ = "airplay"
	}
	var addr string
	if len(e.AddrIPv4) > 0 {
		addr = e.AddrIPv4[0].String()
	}
	if addr == "" {
		return // IPv4-only this slice (probes and phone merge expect v4)
	}
	txt := parseTxt(e.Text)
	name := strings.TrimSpace(e.Instance)
	var deviceId, model string
	if typ == "cast" {
		// §5.4: audio-only Cast devices and cast groups are not screen targets.
		// Cast groups advertise as "Google-Cast-Group-<uuid>" instances; drop
		// them by the (pre-fn) instance name. The `ca` TXT is a DECIMAL
		// capability bitmask whose bit 0 is video-out — exclude a device that
		// positively lacks it. Be lenient when `ca` is absent or unparseable
		// (include): only a definite non-video signal or a group name excludes.
		if strings.HasPrefix(name, "Google-Cast-Group-") {
			return
		}
		if caStr := strings.TrimSpace(txt["ca"]); caStr != "" {
			if ca, err := strconv.Atoi(caStr); err == nil && ca&1 == 0 {
				return
			}
		}
		deviceId = txt["id"]
		model = txt["md"]
		if fn := strings.TrimSpace(txt["fn"]); fn != "" {
			name = fn
		}
	} else {
		deviceId = txt["deviceid"]
		model = txt["model"]
	}
	if name == "" {
		name = addr
	}
	id := typ + ":" + addr
	if deviceId != "" {
		id = typ + ":" + deviceId
	}

	s.mu.Lock()
	t, ok := s.targets[id]
	if !ok {
		t = &castTarget{id: id, typ: typ}
		s.targets[id] = t
	}
	t.name, t.addr, t.port, t.model, t.deviceId = name, addr, e.Port, model, deviceId
	t.present = true
	t.lastSeen = time.Now()
	s.mu.Unlock()
	s.emitIfChanged()
}

func (s *castScanner) evictStale() (changed bool) {
	now := time.Now()
	s.mu.Lock()
	for id, t := range s.targets {
		// Only lost targets age out; a still-present target is never evicted
		// (markAbsent flips present=false and resets lastSeen at the loss).
		if !t.present && now.Sub(t.lastSeen) > castStaleAfter {
			delete(s.targets, id)
			changed = true
		}
	}
	s.mu.Unlock()
	return changed
}

// targetName resolves a target id to its display name for the tray/status.
func (s *castScanner) targetName(id string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if t, ok := s.targets[id]; ok {
		return t.name
	}
	return ""
}

// snapshot builds the full cast.targets message (§5.4/§8.2 — always a full
// snapshot, never a delta). Capability=true appends the synthetic Miracast
// target, without addr/port.
func (s *castScanner) snapshot() map[string]any {
	s.mu.Lock()
	ids := make([]string, 0, len(s.targets))
	for id := range s.targets {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	items := make([]map[string]any, 0, len(ids)+1)
	for _, id := range ids {
		t := s.targets[id]
		it := map[string]any{
			"id": t.id, "name": t.name, "type": t.typ,
			"addr": t.addr, "port": t.port, "seenBy": "host",
		}
		if t.model != "" {
			it["model"] = t.model
		}
		if t.deviceId != "" {
			it["deviceId"] = t.deviceId
		}
		if !t.present {
			it["stale"] = true // §5.4: mDNS-lost, inside the 10 s eviction window
		}
		items = append(items, it)
	}
	s.mu.Unlock()
	if miracastAvailable() {
		items = append(items, map[string]any{
			"id": miracastTargetId, "name": miracastTargetName,
			"type": "miracast", "seenBy": "host",
		})
	}
	return map[string]any{"t": "cast.targets", "items": items}
}

// emitIfChanged broadcasts the snapshot to all subscribers when it differs
// from the last one sent. emitMu serializes concurrent emits so snapshots
// never reach the phone out of order. Content-free logging: counts only.
func (s *castScanner) emitIfChanged() {
	s.emitMu.Lock()
	defer s.emitMu.Unlock()
	snap := s.snapshot()
	data, err := json.Marshal(snap)
	if err != nil || string(data) == s.lastSent {
		return
	}
	s.lastSent = string(data)
	s.mu.Lock()
	subs := make([]*connState, 0, len(s.subs))
	for cs := range s.subs {
		subs = append(subs, cs)
	}
	s.mu.Unlock()
	for _, cs := range subs {
		cs.send(snap)
	}
	logf("cast targets: %d", len(snap["items"].([]map[string]any)))
}

func parseTxt(txt []string) map[string]string {
	m := make(map[string]string, len(txt))
	for _, kv := range txt {
		if k, v, ok := strings.Cut(kv, "="); ok {
			m[strings.ToLower(k)] = v
		}
	}
	return m
}

// --- Session attach registry -------------------------------------------------

// Hello-completed v2 connections, for session pushes (cast.state after hello,
// the 1 Hz cast.status stream, teardown notices). The cast session itself is
// process-global — a phone dropping only detaches its connection here.
var (
	castConnsMu sync.Mutex
	castConns   = map[*connState]struct{}{}
)

// castAttach registers a hello-completed v2 connection and immediately replays
// the active session, if any (§8.4 re-attach: the phone restores its casting
// bar from the unsolicited cast.state).
func castAttach(cs *connState) {
	castConnsMu.Lock()
	castConns[cs] = struct{}{}
	castConnsMu.Unlock()
	castStateOnHello(cs)
}

func castDetach(cs *connState) {
	castConnsMu.Lock()
	delete(castConns, cs)
	castConnsMu.Unlock()
}

func castBroadcast(obj map[string]any) {
	castConnsMu.Lock()
	conns := make([]*connState, 0, len(castConns))
	for cs := range castConns {
		conns = append(conns, cs)
	}
	castConnsMu.Unlock()
	for _, cs := range conns {
		cs.send(obj)
	}
}

// --- Reachability probe --------------------------------------------------------

// castReachReply answers cast.reach (§8.3): a plain TCP connect to the sink,
// 1500 ms budget — the handshake completing is the whole success criterion.
func castReachReply(cs *connState, addr string, port int, rid string) {
	ok := false
	if addr != "" && port > 0 {
		c, err := net.DialTimeout("tcp", net.JoinHostPort(addr, strconv.Itoa(port)), castProbeTimeout)
		if err == nil {
			c.Close()
			ok = true
		}
	}
	cs.send(map[string]any{"t": "cast.reach.res", "rid": rid, "ok": ok})
	logf("cast reach: %v", ok)
}
