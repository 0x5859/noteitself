#!/bin/sh
# Renders the device ink shader offscreen on this Mac's GPU and compares it
# with exact analytic coverage. The iOS Simulator cannot run that shader
# (no framebuffer reads), so this is how it is regression-tested off-device.
set -e
cd "$(dirname "$0")"
OUT="${TMPDIR:-/tmp}/noteitself-shadercheck"
mkdir -p "$OUT"
xcrun -sdk macosx metal -c ../../Sources/Render/Shaders.metal -o "$OUT/shaders.air"
xcrun -sdk macosx metallib "$OUT/shaders.air" -o "$OUT/shaders.metallib"
xcrun -sdk macosx swiftc -O main.swift -o "$OUT/shadercheck"
"$OUT/shadercheck" "$OUT/shaders.metallib"
