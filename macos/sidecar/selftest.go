package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"github.com/pion/webrtc/v4/pkg/media/h264reader"
)

// runSelftest offers a canned H.264 stream to a browser answerer over plain HTTP
// (non-trickle ICE), proving Pion→Chromium H.264 renders with no Chromecast.
func runSelftest(addr, file string) {
	api, err := newAPI(nil)
	if err != nil {
		panic(err)
	}
	pc, err := api.NewPeerConnection(webrtc.Configuration{}) // LAN loopback: no STUN
	if err != nil {
		panic(err)
	}
	videoTrack, err := webrtc.NewTrackLocalStaticSample(
		webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeH264}, "video", "remotype")
	if err != nil {
		panic(err)
	}
	if _, err = pc.AddTrack(videoTrack); err != nil {
		panic(err)
	}
	pc.OnICEConnectionStateChange(func(s webrtc.ICEConnectionState) {
		fmt.Fprintln(os.Stderr, "selftest ICE:", s.String())
		if s == webrtc.ICEConnectionStateConnected {
			go feedH264File(videoTrack, file, 24)
		}
	})

	offer, err := pc.CreateOffer(nil)
	if err != nil {
		panic(err)
	}
	gatherDone := webrtc.GatheringCompletePromise(pc)
	if err = pc.SetLocalDescription(offer); err != nil {
		panic(err)
	}
	<-gatherDone

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		fmt.Fprint(w, answererHTML)
	})
	http.HandleFunc("/offer", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(pc.LocalDescription())
	})
	http.HandleFunc("/answer", func(w http.ResponseWriter, r *http.Request) {
		var ans webrtc.SessionDescription
		if err := json.NewDecoder(r.Body).Decode(&ans); err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		if err := pc.SetRemoteDescription(ans); err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		fmt.Fprintln(os.Stderr, "selftest: answer applied")
		w.WriteHeader(200)
	})
	fmt.Fprintf(os.Stderr, "selftest harness: open http://%s/ in Chrome\n", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		panic(err)
	}
}

// feedH264File loops an Annex-B file, grouping NALs into access units (one frame
// = one WriteSample) at fps — the same shape the real media pipe delivers.
func feedH264File(track *webrtc.TrackLocalStaticSample, file string, fps int) {
	frameDur := time.Second / time.Duration(fps)
	for {
		f, err := os.Open(file)
		if err != nil {
			fmt.Fprintln(os.Stderr, "feedH264 open:", err)
			return
		}
		reader, err := h264reader.NewReader(f)
		if err != nil {
			f.Close()
			return
		}
		var au []byte
		haveVCL := false
		ticker := time.NewTicker(frameDur)
		flush := func() {
			if len(au) > 0 {
				<-ticker.C
				if err := track.WriteSample(media.Sample{Data: au, Duration: frameDur}); err != nil {
					fmt.Fprintln(os.Stderr, "WriteSample:", err)
				}
			}
			au = nil
			haveVCL = false
		}
		for {
			nal, err := reader.NextNAL()
			if err != nil {
				break
			}
			t := nal.UnitType
			isVCL := t >= 1 && t <= 5
			if isVCL && haveVCL {
				flush()
			}
			au = append(au, 0x00, 0x00, 0x00, 0x01)
			au = append(au, nal.Data...)
			if isVCL {
				haveVCL = true
			}
		}
		flush()
		ticker.Stop()
		f.Close()
	}
}

const answererHTML = `<!doctype html><html><head><meta charset=utf-8>
<title>Remotype selftest answerer</title>
<style>html,body{margin:0;height:100%;background:#000}video{width:100%;height:100%;object-fit:contain}
#s{position:fixed;top:8px;left:8px;color:#0f0;font:14px monospace;background:#000a;padding:4px 8px}</style>
</head><body><video id=v autoplay playsinline muted></video><div id=s>starting…</div>
<script>
const log = m => { document.getElementById('s').textContent = m; console.log(m); };
(async () => {
  const pc = new RTCPeerConnection({iceServers: []});
  pc.ontrack = e => { document.getElementById('v').srcObject = e.streams[0]; log('track received'); };
  pc.oniceconnectionstatechange = () => log('ICE: ' + pc.iceConnectionState);
  const offer = await (await fetch('/offer')).json();
  await pc.setRemoteDescription(offer);
  const answer = await pc.createAnswer();
  await pc.setLocalDescription(answer);
  await new Promise(r => { if (pc.iceGatheringState === 'complete') r();
    else pc.addEventListener('icegatheringstatechange', () => pc.iceGatheringState === 'complete' && r()); });
  await fetch('/answer', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(pc.localDescription)});
  log('answer sent — waiting for video');
})();
</script></body></html>`
