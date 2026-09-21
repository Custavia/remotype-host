#!/bin/bash
# SUPERSEDED — see build-opus-universal.sh.
#
# This script copied Homebrew's libopus.a, which on Apple Silicon is arm64 only.
# Because the cast helper links it statically, that one file is what made every
# release through 1.0.2 arm64-only — an app Intel Macs could not launch at all.
# Left as a stub rather than deleted so it fails loudly instead of quietly
# re-thinning the build.
echo "vendor-opus.sh is superseded — it produced a single-architecture libopus." >&2
echo "Use: ./sidecar/build-opus-universal.sh" >&2
exit 1
