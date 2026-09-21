package main

import (
	"fmt"
	"io"
	"log"
	"os"
)

// Logging goes to stdout, timestamped, which is what a terminal, a systemd
// unit and a Lima shell all want. REMOTYPE_HOST_LOG names a file to mirror
// into as well — the RT1 spec probes tail a host log to prove what the host
// did, and they should not have to capture stdout to do it.
func initLog() {
	log.SetFlags(log.LstdFlags)
	w := io.Writer(os.Stdout)
	if path := os.Getenv("REMOTYPE_HOST_LOG"); path != "" {
		f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		if err == nil {
			w = io.MultiWriter(os.Stdout, f)
		} else {
			fmt.Fprintf(os.Stderr, "could not open REMOTYPE_HOST_LOG %s: %v\n", path, err)
		}
	}
	log.SetOutput(w)
}

func logf(format string, a ...any) { log.Printf(format, a...) }
