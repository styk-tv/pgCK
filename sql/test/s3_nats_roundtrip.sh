#!/usr/bin/env bash
set -euo pipefail

server="nats://${NATS_HOST:-127.0.0.1}:${NATS_PORT:-4222}"
trace_id="tx-s3-roundtrip"
out_file="$(mktemp)"
sub_pid=""

cleanup() {
  if [[ -n "${sub_pid}" ]] && kill -0 "${sub_pid}" 2>/dev/null; then
    kill "${sub_pid}" 2>/dev/null || true
  fi
  rm -f "${out_file}"
}

trap cleanup EXIT

command -v nats >/dev/null 2>&1 || {
  echo "nats CLI not found on PATH" >&2
  exit 1
}

nats --server "${server}" sub 'event.demo.Hello.>' --count=1 >"${out_file}" 2>&1 &
sub_pid=$!
sleep 1

nats --server "${server}" pub 'event.demo.Hello.created' \
  "{\"trace_id\":\"${trace_id}\",\"data\":{\"status\":\"created\"}}" >/dev/null

wait "${sub_pid}"

if grep -q "${trace_id}" "${out_file}"; then
  echo "ROUNDTRIP OK"
else
  echo "ROUNDTRIP FAIL" >&2
  cat "${out_file}" >&2
  exit 1
fi
