//go:build windows

// Clipboard FILE transfer (CLIPBOARD.md phase 2) — the vault's binary half.
//
//   Push (phone → PC): clip.file.push {id,name,size} → chunks {id,seq,data(b64)}
//     → clip.file.done → file lands in the clipboard download folder AND on the
//     PC's clipboard as a real file (CF_HDROP), so Ctrl+V in Explorer pastes it.
//     Reply: clip.file.saved {id, path}.
//   Pull (PC → phone): clip.file.pull {id} → if the clipboard holds a file within
//     the cap: clip.file.meta {id,name,size} + chunks + clip.file.done; else
//     clip.file.err {id, reason: nofile|toolarge}.
//
// Chunks are ≤48KB of raw bytes, base64-encoded onto the existing JSON-lines
// channel — no second socket, no new firewall surface.
package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

const (
	clipFileMaxBytes = 32 << 20 // 32 MB — generous for documents, sane for RAM
	clipFileChunk    = 48 << 10
)

var procDragQueryFileW = shell32.NewProc("DragQueryFileW") // shell32 from extras_windows.go

func utf16FromString(s string) []uint16 {
	u, _ := syscall.UTF16FromString(s)
	if n := len(u); n > 0 && u[n-1] == 0 { // helper strings carry no NUL; we add our own
		u = u[:n-1]
	}
	return u
}

func utf16ToString(u []uint16) string { return syscall.UTF16ToString(u) }

// in-flight push assembly (single transfer at a time — the phone serializes)
var pushBuf struct {
	id   string // flexID rendered to its JSON text — stable correlation token
	name string
	size int
	data []byte
}

func fid(m msg) string { b, _ := m.Id.MarshalJSON(); return string(b) }

func clipDownloadDir() string {
	home, _ := os.UserHomeDir()
	dir := filepath.Join(home, "Downloads", "Remotype")
	os.MkdirAll(dir, 0o755)
	return dir
}

// sanitizeName strips path separators so a hostile name can't escape the folder.
func sanitizeName(name string) string {
	name = filepath.Base(strings.ReplaceAll(name, "\\", "/"))
	if name == "" || name == "." {
		name = "clipboard.bin"
	}
	return name
}

// dedupePath returns a free path, appending " (n)" before the extension.
func dedupePath(dir, name string) string {
	p := filepath.Join(dir, name)
	if _, err := os.Stat(p); os.IsNotExist(err) {
		return p
	}
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	for i := 2; ; i++ {
		p = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", stem, i, ext))
		if _, err := os.Stat(p); os.IsNotExist(err) {
			return p
		}
	}
}

func clipFilePush(cs *connState, m msg) {
	if m.Size <= 0 || m.Size > clipFileMaxBytes {
		cs.send(map[string]any{"t": "clip.file.err", "id": m.Id, "reason": "toolarge"})
		return
	}
	pushBuf.id, pushBuf.name, pushBuf.size = fid(m), sanitizeName(m.Name), m.Size
	pushBuf.data = make([]byte, 0, m.Size)
	cs.send(map[string]any{"t": "clip.file.ok", "id": m.Id})
}

func clipFileChunk_(cs *connState, m msg) {
	if fid(m) != pushBuf.id {
		return
	}
	raw, err := base64.StdEncoding.DecodeString(m.Data)
	if err != nil || len(pushBuf.data)+len(raw) > pushBuf.size {
		pushBuf.id = ""
		cs.send(map[string]any{"t": "clip.file.err", "id": m.Id, "reason": "corrupt"})
		return
	}
	pushBuf.data = append(pushBuf.data, raw...)
}

func clipFileDone(cs *connState, m msg) {
	if fid(m) != pushBuf.id {
		return
	}
	path := dedupePath(clipDownloadDir(), pushBuf.name)
	if err := os.WriteFile(path, pushBuf.data, 0o644); err != nil {
		cs.send(map[string]any{"t": "clip.file.err", "id": m.Id, "reason": "write"})
		pushBuf.id = ""
		return
	}
	setClipboardFile(path) // Ctrl+V in Explorer now pastes the file itself
	logf("clipboard file saved: %s (%d bytes)", filepath.Base(path), len(pushBuf.data))
	cs.send(map[string]any{"t": "clip.file.saved", "id": m.Id, "path": path})
	pushBuf.id = ""
	pushBuf.data = nil
}

func clipFilePull(cs *connState, m msg) {
	path, ok := getClipboardFile()
	if !ok {
		cs.send(map[string]any{"t": "clip.file.err", "id": m.Id, "reason": "nofile"})
		return
	}
	info, err := os.Stat(path)
	if err != nil || info.Size() > clipFileMaxBytes {
		cs.send(map[string]any{"t": "clip.file.err", "id": m.Id, "reason": "toolarge"})
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		cs.send(map[string]any{"t": "clip.file.err", "id": m.Id, "reason": "read"})
		return
	}
	cs.send(map[string]any{"t": "clip.file.meta", "id": m.Id,
		"name": filepath.Base(path), "size": len(data)})
	for seq, off := 0, 0; off < len(data); seq, off = seq+1, off+clipFileChunk {
		end := off + clipFileChunk
		if end > len(data) {
			end = len(data)
		}
		cs.send(map[string]any{"t": "clip.file.chunk", "id": m.Id, "seq": seq,
			"data": base64.StdEncoding.EncodeToString(data[off:end])})
	}
	cs.send(map[string]any{"t": "clip.file.done", "id": m.Id})
	logf("clipboard file sent: %s (%d bytes)", filepath.Base(path), len(data))
}

// ---- Win32 clipboard: CF_HDROP get + set ------------------------------------

const cfHDROP = 15

// getClipboardFile returns the FIRST file on the clipboard (Explorer copy).
func getClipboardFile() (string, bool) {
	if r, _, _ := procOpenClipboard.Call(0); r == 0 {
		return "", false
	}
	defer procCloseClipboard.Call()
	h, _, _ := procGetClipboardData.Call(cfHDROP)
	if h == 0 {
		return "", false
	}
	p, _, _ := procGlobalLock.Call(h)
	if p == 0 {
		return "", false
	}
	defer procGlobalUnlock.Call(h)
	// DRAGQUERYFILE via shell32.
	n, _, _ := procDragQueryFileW.Call(p, 0xFFFFFFFF, 0, 0)
	if n == 0 {
		return "", false
	}
	buf := make([]uint16, 4096)
	ln, _, _ := procDragQueryFileW.Call(p, 0, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if ln == 0 {
		return "", false
	}
	return utf16ToString(buf[:ln]), true
}

// setClipboardFile puts [path] on the clipboard as CF_HDROP (DROPFILES + UTF-16
// double-NUL list), so file managers paste the actual file.
func setClipboardFile(path string) bool {
	u16 := utf16FromString(path)
	// DROPFILES{pFiles=20,pt,fNC,fWide=1} + files + double NUL
	const dropfilesSize = 20
	total := dropfilesSize + (len(u16)+2)*2
	if r, _, _ := procOpenClipboard.Call(0); r == 0 {
		return false
	}
	defer procCloseClipboard.Call()
	procEmptyClipboard.Call()
	h, _, _ := procGlobalAlloc.Call(gmemMoveable, uintptr(total))
	if h == 0 {
		return false
	}
	p, _, _ := procGlobalLock.Call(h)
	if p == 0 {
		return false
	}
	// header
	*(*uint32)(unsafe.Pointer(p)) = dropfilesSize // pFiles
	*(*uint32)(unsafe.Pointer(p + 16)) = 1        // fWide
	dst := unsafe.Slice((*uint16)(unsafe.Pointer(p+dropfilesSize)), len(u16)+2)
	copy(dst, u16)
	dst[len(u16)] = 0
	dst[len(u16)+1] = 0
	procGlobalUnlock.Call(h)
	if r, _, _ := procSetClipboardData.Call(cfHDROP, h); r == 0 {
		procGlobalFree.Call(h)
		return false
	}
	return true
}
