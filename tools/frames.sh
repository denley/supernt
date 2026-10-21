#!/bin/sh
# Extract frames from a console video for reading test screens.
# Usage: tools/frames.sh video.mov outdir [fps]   (default 1 frame per second, full size)
# Uses imageio-ffmpeg's binary from ~/scratch/ffvenv if there is no ffmpeg on PATH.
set -e
FF=$(command -v ffmpeg || ls ~/scratch/ffvenv/lib/python3*/site-packages/imageio_ffmpeg/binaries/ffmpeg-* | head -n 1)
mkdir -p "$2"
"$FF" -v error -i "$1" -vf "fps=${3:-1}" "$2/f%03d.jpg"
ls "$2" | wc -l
