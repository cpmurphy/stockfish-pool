#!/usr/bin/env bash
# Builds localhost/stockfish-pool:latest from this repository root.
#
#   deploy/build-image.sh
#   STOCKFISH_ARCH=x86-64-sse41-popcnt deploy/build-image.sh
set -euo pipefail

cd "$(dirname "$0")/.."
arch="${STOCKFISH_ARCH:-x86-64-avx2}"

if [ -z "${STOCKFISH_ARCH:-}" ] && ! grep -qw avx2 /proc/cpuinfo; then
  echo "This CPU has no AVX2; rerun with STOCKFISH_ARCH=x86-64-sse41-popcnt" >&2
  exit 1
fi

git submodule update --init Stockfish
podman build -f Containerfile --build-arg STOCKFISH_ARCH="$arch" \
  -t localhost/stockfish-pool:latest .
echo "Built localhost/stockfish-pool:latest"
