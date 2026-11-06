#!/usr/bin/env bash
# Starts a throwaway Synapse, runs the interop scenarios, removes Synapse.
# Set KEEP_SYNAPSE=1 to leave the server running afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${KEEP_SYNAPSE:-}" != "1" ]]; then
  trap 'bash interop/synapse.sh down' EXIT
fi
bash interop/synapse.sh up
MATRIX_HOMESERVER="http://127.0.0.1:${SYNAPSE_PORT:-8008}" \
  moon run --target native interop
