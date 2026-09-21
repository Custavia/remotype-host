//go:build !windows

package main

// Non-Windows builds: the file half of the clipboard vault answers "nofile" so
// a phone probing an unsupported platform gets an honest error, not silence.
func clipFilePush(cs *connState, m msg)   { cs.send(map[string]any{"t": "clip.file.err", "id": m.Id, "reason": "unsupported"}) }
func clipFileChunk_(cs *connState, m msg) {}
func clipFileDone(cs *connState, m msg)   {}
func clipFilePull(cs *connState, m msg)   { cs.send(map[string]any{"t": "clip.file.err", "id": m.Id, "reason": "unsupported"}) }
