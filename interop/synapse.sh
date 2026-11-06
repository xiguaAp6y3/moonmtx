#!/usr/bin/env bash
# Local Synapse for the interop check.
#
#   interop/synapse.sh up     start Synapse on 127.0.0.1:8008, register users
#   interop/synapse.sh down   stop it and delete its data
#
# Uses a named Docker volume, so it needs no host paths and works the same in
# Git Bash on Windows and on Linux.
set -euo pipefail

IMAGE="${SYNAPSE_IMAGE:-ghcr.io/element-hq/synapse:v1.164.2}"
NAME=moonmtx-synapse
VOLUME=moonmtx-synapse-data
PORT="${SYNAPSE_PORT:-8008}"
SERVER_NAME=localhost
SECRET=moonmtx-interop-secret
PASSWORD=moonmtx-interop-pw
export MSYS_NO_PATHCONV=1

down() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
}

up() {
  down
  docker volume create "$VOLUME" >/dev/null
  docker run --rm -v "$VOLUME:/data" \
    -e SYNAPSE_SERVER_NAME="$SERVER_NAME" -e SYNAPSE_REPORT_STATS=no \
    "$IMAGE" generate >/dev/null
  # Test-only settings: a known registration secret and rate limits high
  # enough that the scripted scenarios are deterministic.
  docker run --rm -i -v "$VOLUME:/data" --entrypoint sh "$IMAGE" -c '
    sed -i "/^registration_shared_secret:/d" /data/homeserver.yaml
    echo >> /data/homeserver.yaml
    cat >> /data/homeserver.yaml' <<EOF
registration_shared_secret: "$SECRET"
rc_message:
  per_second: 1000
  burst_count: 1000
rc_login:
  address: {per_second: 1000, burst_count: 1000}
  account: {per_second: 1000, burst_count: 1000}
  failed_attempts: {per_second: 1000, burst_count: 1000}
rc_joins:
  local: {per_second: 1000, burst_count: 1000}
rc_invites:
  per_room: {per_second: 1000, burst_count: 1000}
  per_user: {per_second: 1000, burst_count: 1000}
EOF
  docker run -d --name "$NAME" -v "$VOLUME:/data" \
    -p "127.0.0.1:$PORT:8008" "$IMAGE" >/dev/null
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:$PORT/_matrix/client/versions" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  curl -fsS "http://127.0.0.1:$PORT/_matrix/client/versions" >/dev/null
  for user in alice bob; do
    docker exec "$NAME" register_new_matrix_user \
      -u "$user" -p "$PASSWORD" --no-admin -k "$SECRET" http://localhost:8008 >/dev/null
  done
  echo "Synapse $(docker exec "$NAME" python -c 'import synapse;print(synapse.__version__)') on http://127.0.0.1:$PORT"
  echo "users: @alice:$SERVER_NAME @bob:$SERVER_NAME password: $PASSWORD"
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  *) echo "usage: $0 up|down" >&2; exit 2 ;;
esac
