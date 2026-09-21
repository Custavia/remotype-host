import Foundation

/// The self-contained HTML receiver page served by the host at `/c/<token>`
/// (CASTING.md §9.6-browser / Tier B0). Same-origin with the MJPEG stream, so
/// no HTTPS / CORS / secure-context is required. Everything (CSS + JS) is inline
/// — it works on a LAN with zero internet. The computer name and per-session
/// token are substituted at serve time; both are injected as JSON-encoded JS
/// string literals so an odd computer name can't break the markup.
enum BrowserReceiver {

    /// Build the receiver page for a session. `computer` is the Mac's name (shown
    /// in the title + reconnect copy); `token` is the base64url session token
    /// used in the stream/ping paths.
    static func page(computer: String, token: String, audio: Bool) -> Data {
        let jsComputer = jsLiteral(computer)
        let jsToken = jsLiteral(token)
        let jsAudio = audio ? "true" : "false"
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>Remotype</title>
        <style>
          :root { color-scheme: dark; }
          * { margin: 0; padding: 0; box-sizing: border-box; }
          html, body { width: 100%; height: 100%; background: #0b0d10; overflow: hidden;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
          #stage { position: fixed; inset: 0; display: flex; align-items: center;
            justify-content: center; background: #0b0d10; }
          #video { max-width: 100%; max-height: 100%; width: auto; height: auto;
            object-fit: contain; display: none; }
          #title { position: fixed; top: 18px; left: 0; right: 0; text-align: center;
            color: #e9edf2; font-size: 15px; font-weight: 600; letter-spacing: .2px;
            text-shadow: 0 1px 3px rgba(0,0,0,.6); opacity: 1;
            transition: opacity 1.1s ease; pointer-events: none; }
          #title.faded { opacity: 0; }
          .overlay { position: fixed; inset: 0; display: none; flex-direction: column;
            align-items: center; justify-content: center; gap: 14px; color: #e9edf2;
            background: #0b0d10; text-align: center; padding: 24px; }
          .overlay.show { display: flex; }
          .spinner { width: 34px; height: 34px; border-radius: 50%;
            border: 3px solid rgba(233,237,242,.22); border-top-color: #e9edf2;
            animation: spin 1s linear infinite; }
          @keyframes spin { to { transform: rotate(360deg); } }
          @media (prefers-reduced-motion: reduce) { .spinner { animation: none; } }
          .msg { font-size: 16px; font-weight: 500; color: #c7ced6; max-width: 30ch; }
          .obrand { display: inline-flex; align-items: center; gap: 10px; margin-bottom: 6px; }
          .obrand .glyph { width: 30px; height: 30px; border-radius: 8px;
            background: linear-gradient(160deg, #3b82f6, #2563eb);
            display: flex; align-items: center; justify-content: center; }
          .obrand .glyph svg { width: 18px; height: 18px; }
          .obrand .wm { text-align: left; line-height: 1.1; }
          .obrand .wm .name { font-size: 17px; font-weight: 700; }
          .obrand .wm .by { font-size: 11px; color: #8b95a2; font-weight: 500; }
          .btn { background: #3b82f6; color: #fff; border: 0; border-radius: 10px;
            padding: 11px 20px; font-size: 15px; font-weight: 600; cursor: pointer; }
          .btn:hover { background: #2f6fe0; }
          #controls { position: fixed; bottom: 18px; right: 18px; z-index: 5;
            display: flex; gap: 10px; }
          #controls button { background: rgba(30,34,40,.82); color: #e9edf2;
            border: 1px solid rgba(255,255,255,.14); border-radius: 999px;
            padding: 9px 15px; font-size: 14px; font-weight: 600; cursor: pointer;
            -webkit-backdrop-filter: blur(8px); backdrop-filter: blur(8px); }
          #controls button:disabled { opacity: .6; cursor: default; }
          #controls button[hidden] { display: none; }
        </style>
        </head>
        <body>
          <div id="stage"><img id="video" alt=""></div>
          <div id="title"></div>
          <div id="reconnect" class="overlay">
            <div class="spinner"></div>
            <div class="msg" id="reconnectMsg"></div>
          </div>
          <div id="ended" class="overlay">
            \(brandOverlay())
            <div class="msg" id="endedMsg">Cast ended</div>
            <div class="msg" style="font-size:14px;color:#8b95a2">Start a new cast from Remotype on your phone.</div>
          </div>
          <div id="stopped" class="overlay">
            \(brandOverlay())
            <div class="msg">You stopped viewing</div>
            <button class="btn" id="resume" type="button">Resume viewing</button>
          </div>
          <div id="controls">
            <button id="stopview" type="button">Stop viewing</button>
            <button id="sound" type="button">🔊 Enable sound</button>
          </div>
        <script>
        (function () {
          var TOKEN = \(jsToken);
          var COMPUTER = \(jsComputer);
          var AUDIO = \(jsAudio);
          var base = "/c/" + TOKEN;
          var video = document.getElementById("video");
          var title = document.getElementById("title");
          var reconnect = document.getElementById("reconnect");
          var reconnectMsg = document.getElementById("reconnectMsg");
          var ended = document.getElementById("ended");
          var stopped = document.getElementById("stopped");
          var controls = document.getElementById("controls");
          var sound = document.getElementById("sound");
          var stopview = document.getElementById("stopview");
          var resume = document.getElementById("resume");
          var isEnded = false;
          var isStopped = false;
          var retryTimer = null;
          var titleTimer = null;

          title.textContent = "Remotype — " + COMPUTER;
          reconnectMsg.textContent = "Reconnecting to " + COMPUTER + "\\u2026";

          function fadeTitle() {
            clearTimeout(titleTimer);
            title.classList.remove("faded");
            titleTimer = setTimeout(function () { title.classList.add("faded"); }, 3800);
          }

          function showEnded() {
            if (isEnded) return;
            isEnded = true;
            clearTimeout(retryTimer);
            disconnectAudio();
            video.removeAttribute("src");
            video.style.display = "none";
            reconnect.classList.remove("show");
            stopped.classList.remove("show");
            controls.style.display = "none";
            title.classList.add("faded");
            ended.classList.add("show");
          }

          function loadStream() {
            if (isEnded) return;
            // Cache-buster so the browser reopens the multipart stream rather
            // than reusing a dead connection.
            video.src = base + "/stream?r=" + Date.now();
          }

          video.addEventListener("load", function () {
            if (isEnded) return;
            reconnect.classList.remove("show");
            video.style.display = "block";
            fadeTitle();
          });
          video.addEventListener("error", function () {
            if (isEnded) return;
            video.style.display = "none";
            reconnect.classList.add("show");
            poll();   // an error is often the host tearing down — check for 410 NOW,
                      // don't wait for the next interval (else "Reconnecting…" lingers)
            clearTimeout(retryTimer);
            retryTimer = setTimeout(loadStream, 1500);
          });

          // Liveness poll: a 410 on the token path means the host tore the cast
          // down — show "Cast ended". A network error is just a blip; keep trying.
          function poll() {
            if (isEnded) return;
            fetch(base + "/ping", { cache: "no-store" }).then(function (res) {
              if (res.status === 410) showEnded();
            }).catch(function () {});
          }
          setInterval(poll, 2000);

          // Best-effort screen wake-lock so a laptop/TV browser doesn't dim.
          var wakeLock = null;
          function requestWakeLock() {
            if (!("wakeLock" in navigator)) return;
            navigator.wakeLock.request("screen").then(function (wl) {
              wakeLock = wl;
            }).catch(function () {});
          }
          requestWakeLock();
          document.addEventListener("visibilitychange", function () {
            if (document.visibilityState === "visible") requestWakeLock();
          });

          // Stop viewing: leave this browser's stream (the cast keeps running for
          // the phone + any other viewer). Closing the tab does the same, but the
          // explicit button + a Resume is friendlier for the person watching.
          function stopViewing() {
            if (isEnded || isStopped) return;
            isStopped = true;
            clearTimeout(retryTimer);
            disconnectAudio();
            video.removeAttribute("src");     // drops the connection → host viewer-count falls
            video.style.display = "none";
            reconnect.classList.remove("show");
            controls.style.display = "none";
            title.classList.add("faded");
            stopped.classList.add("show");
          }
          function resumeViewing() {
            if (isEnded) return;
            isStopped = false;
            stopped.classList.remove("show");
            controls.style.display = "flex";
            loadStream();
          }
          stopview.addEventListener("click", stopViewing);
          resume.addEventListener("click", resumeViewing);

          // Enable sound (§6.2): computer audio streams as 48 kHz mono Int16 PCM
          // over a WebSocket; we feed it to WebAudio through a small jitter buffer.
          // A user gesture (the click) is required before a browser lets audio play.
          // audioNode MUST stay referenced at this scope — Chrome garbage-collects
          // an unreferenced ScriptProcessorNode and onaudioprocess stops firing
          // (a classic silent-audio bug). We use ScriptProcessorNode, not the
          // modern AudioWorklet, because addModule needs a secure context and the
          // receiver is plain http on the LAN.
          var audioCtx = null, ws = null, audioNode = null, audioOn = false;
          var queue = [];            // Float32Array chunks awaiting playback
          var queued = 0;            // samples buffered
          var PREBUFFER = 4800;      // ~100 ms at 48 kHz before we start
          var MAXBUFFER = 24000;     // ~500 ms cap — drop oldest past this
          var started = false;
          if (!AUDIO) { sound.hidden = true; }

          function enableSound() {
            if (audioOn) { disconnectAudio(); return; }
            audioOn = true;
            sound.textContent = "🔇 Mute";
            try {
              audioCtx = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 48000 });
            } catch (e) { audioCtx = new (window.AudioContext || window.webkitAudioContext)(); }
            // 4096-frame buffer (steadier over LAN jitter) + 1 input channel
            // (unused, but some browsers won't fire onaudioprocess with 0 inputs).
            audioNode = audioCtx.createScriptProcessor(4096, 1, 1);
            audioNode.onaudioprocess = function (ev) {
              var out = ev.outputBuffer.getChannelData(0);
              if (!started) { for (var i = 0; i < out.length; i++) out[i] = 0; return; }
              for (var j = 0; j < out.length; j++) {
                if (queue.length) {
                  var chunk = queue[0];
                  out[j] = chunk[chunk.pos]; chunk.pos++; queued--;
                  if (chunk.pos >= chunk.length) queue.shift();
                } else { out[j] = 0; }   // underrun → silence
              }
            };
            audioNode.connect(audioCtx.destination);
            audioCtx.resume();
            var proto = location.protocol === "https:" ? "wss://" : "ws://";
            ws = new WebSocket(proto + location.host + base + "/audio");
            ws.binaryType = "arraybuffer";
            ws.onmessage = function (ev) {
              var i16 = new Int16Array(ev.data);
              var f32 = new Float32Array(i16.length);
              for (var k = 0; k < i16.length; k++) f32[k] = i16[k] / 32768;
              f32.pos = 0; queue.push(f32); queued += f32.length;
              while (queued > MAXBUFFER && queue.length) { queued -= (queue[0].length - queue[0].pos); queue.shift(); }
              if (!started && queued >= PREBUFFER) started = true;
            };
          }
          function disconnectAudio() {
            audioOn = false; started = false; queue = []; queued = 0;
            sound.textContent = "🔊 Enable sound";
            if (ws) { try { ws.close(); } catch (e) {} ws = null; }
            if (audioNode) { try { audioNode.disconnect(); audioNode.onaudioprocess = null; } catch (e) {} audioNode = null; }
            if (audioCtx) { try { audioCtx.close(); } catch (e) {} audioCtx = null; }
          }
          sound.addEventListener("click", enableSound);

          loadStream();
          fadeTitle();
        })();
        </script>
        </body>
        </html>
        """
        return Data(html.utf8)
    }

    /// The branded landing page served at the bare root (the typeable "host:port"
    /// the phone shows). A 256-bit token is untypeable, so the human path in is
    /// the 4-digit code: enter it + "Start Casting" → GET /?code=NNNN → a 302 to
    /// the canonical /c/<token> receiver. `wrong` shows a mismatch hint; `ended`
    /// means the cast is over (served with 410).
    static func codeEntryPage(wrong: Bool, ended: Bool) -> String {
        let heading = ended ? "Cast ended" : "Cast to this screen"
        let sub = ended
            ? "This cast has stopped. Start a new one from your phone."
            : "Enter the 4-digit code shown in Remotype on your phone, then Start Casting — your computer's screen appears here."
        let hint = wrong ? #"<p class="err">That code didn't match — check your phone and try again.</p>"# : ""
        let form = ended ? "" : """
          <form method="get" action="/" autocomplete="off">
            <input name="code" inputmode="numeric" pattern="[0-9]*" maxlength="4"
                   autocomplete="off" autofocus placeholder="0000" aria-label="4-digit code">
            <button type="submit">Start Casting</button>
          </form>
        """
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Remotype</title>
        <style>
          :root { color-scheme: dark; }
          * { margin: 0; padding: 0; box-sizing: border-box; }
          html, body { height: 100%;
            background: radial-gradient(120% 90% at 50% -10%, #17202c 0%, #0b0d10 55%);
            color: #e7ebf0;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, sans-serif; }
          body { display: flex; align-items: center; justify-content: center; padding: 24px; }
          .card { width: 100%; max-width: 380px; text-align: center; }
          .brand { display: inline-flex; align-items: center; gap: 10px; margin-bottom: 26px; }
          .glyph { width: 34px; height: 34px; border-radius: 9px;
            background: linear-gradient(160deg, #3b82f6, #2563eb);
            display: flex; align-items: center; justify-content: center;
            box-shadow: 0 6px 18px rgba(37,99,235,.4); }
          .glyph svg { width: 20px; height: 20px; }
          .wordmark { text-align: left; line-height: 1.1; }
          .wordmark .name { font-size: 19px; font-weight: 700; letter-spacing: .2px; }
          .wordmark .by { font-size: 12px; color: #8b95a2; font-weight: 500; }
          h1 { font-size: 21px; font-weight: 600; margin-bottom: 10px; }
          p { color: #9aa4b0; font-size: 14.5px; line-height: 1.5; margin-bottom: 22px; }
          p.err { color: #ff9f68; }
          form { display: flex; flex-direction: column; gap: 12px; }
          input { font-size: 30px; letter-spacing: 12px; text-align: center; font-weight: 600;
            padding: 14px; border-radius: 12px; border: 1px solid #2a3038;
            background: #12161c; color: #e7ebf0; outline: none; }
          input:focus { border-color: #3b82f6; box-shadow: 0 0 0 3px rgba(59,130,246,.25); }
          button { padding: 14px; border: 0; border-radius: 12px; font-size: 16px;
            font-weight: 700; background: #3b82f6; color: #fff; cursor: pointer;
            transition: background .15s ease; }
          button:hover { background: #2f6fe0; }
          .foot { margin-top: 24px; font-size: 12px; color: #6b7480; }
        </style>
        </head>
        <body>
          <div class="card">
            <div class="brand">
              <span class="glyph"><svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                <rect x="2.5" y="4" width="19" height="12.5" rx="2" stroke="#fff" stroke-width="1.7"/>
                <path d="M8 20h8" stroke="#fff" stroke-width="1.7" stroke-linecap="round"/></svg></span>
              <span class="wordmark"><div class="name">Remotype</div><div class="by">by Custavia</div></span>
            </div>
            <h1>\(heading)</h1>
            <p>\(sub)</p>
            \(hint)
            \(form)
            <div class="foot">Your computer streams here. Your phone stays the remote.</div>
          </div>
        </body>
        </html>
        """
    }

    /// Remotype + Custavia brand lockup for the receiver's full-screen overlays
    /// (Cast ended / Stopped). Styled by the `.obrand` rules in the page CSS.
    private static func brandOverlay() -> String {
        """
        <div class="obrand">
          <span class="glyph"><svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
            <rect x="2.5" y="4" width="19" height="12.5" rx="2" stroke="#fff" stroke-width="1.7"/>
            <path d="M8 20h8" stroke="#fff" stroke-width="1.7" stroke-linecap="round"/></svg></span>
          <span class="wm"><div class="name">Remotype</div><div class="by">by Custavia</div></span>
        </div>
        """
    }

    /// JSON-encode a string into a JS/HTML-safe double-quoted literal.
    private static func jsLiteral(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s),
              let str = String(data: data, encoding: .utf8) else { return "\"\"" }
        return str
    }
}
