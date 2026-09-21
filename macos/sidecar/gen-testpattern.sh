#!/bin/bash
# Regenerate the H.264 test stream the --selftest harness feeds the video track.
# Constrained Baseline / level 3.1 / 720p24 / 1s GOP / no B-frames / ~2.5 Mbps —
# i.e. exactly the legacy-Chromecast target settings from docs/CASTING.md §6.5, so the
# loopback exercises the real codec path our VTCompressionSession will emit.
set -euo pipefail
cd "$(dirname "$0")"
ffmpeg -y -f lavfi -i "testsrc2=size=1280x720:rate=24,format=yuv420p" \
  -t 8 -c:v libx264 -profile:v baseline -level 3.1 -pix_fmt yuv420p \
  -g 24 -keyint_min 24 -x264-params "annexb=1:bframes=0:scenecut=0:repeat-headers=1" \
  -b:v 2500k -an testpattern.h264
echo "wrote testpattern.h264"
