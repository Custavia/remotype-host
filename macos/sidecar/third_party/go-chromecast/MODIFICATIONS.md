# Modifications to go-chromecast

This directory is a fork of [go-chromecast](https://github.com/vishen/go-chromecast)
v0.3.4 by Jonathan Rudenberg and contributors, used under the Apache License 2.0
(see `LICENSE`). This file records the changes, as Apache-2.0 section 4(b) requires.

## cast/connection.go

Upstream, an incoming Cast message with no `"type"` key in its payload is logged and
discarded. Messages on an application's own CUSTOM namespace are application-defined
and need not carry Google's `"type"` key — the Remotype Cast receiver replies with
`{"kind":"answer"|"ice"|"ready", ...}` — so the WebRTC answer never reached the
sender and every cast stayed in "connecting". The fork forwards such messages to the
receive channel instead of dropping them. The change is marked in place with a
`PATCH (Remotype)` comment.

No other file differs from upstream v0.3.4.
