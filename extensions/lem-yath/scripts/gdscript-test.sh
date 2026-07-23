#!/usr/bin/env bash
# Real-ncurses regression for the configured external Godot LSP connection.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-gdscript-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-gdscript.XXXXXX")"
session="lem-yath-gdscript-$id"
server_pid=""

cleanup() {
  lem_stop "$session" || true
  if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export XDG_CONFIG_HOME="$root/config"
export WORKDIR="$root/work"
export LEM_YATH_GDSCRIPT_TEST_REPORT="$root/report"
export LEM_YATH_GDSCRIPT_TEST_EVENTS="$root/events"

project="$root/project"
settings="$XDG_CONFIG_HOME/godot"
port_file="$root/port"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" "$project" "$settings"
: >"$LEM_YATH_GDSCRIPT_TEST_REPORT"
: >"$LEM_YATH_GDSCRIPT_TEST_EVENTS"

printf '%s\n' \
  'config_version=5' \
  'config/features=PackedStringArray("4.6", "GL Compatibility")' \
  >"$project/project.godot"
printf '%s\n' 'extends Node' 'func ready():' $'\tpass' \
  >"$project/player.gd"

python3 "$here/scripts/fake-lsp-server.py" \
  --events "$LEM_YATH_GDSCRIPT_TEST_EVENTS" \
  --tcp-port 0 \
  --port-file "$port_file" &
server_pid=$!

for _index in {1..80}; do
  if [ -s "$port_file" ]; then
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo 'Fake Godot LSP server exited before publishing its port.' >&2
    exit 1
  fi
  sleep 0.05
done
if [ ! -s "$port_file" ]; then
  echo 'Timed out waiting for the fake Godot LSP port.' >&2
  exit 1
fi
port=$(tr -d '[:space:]' <"$port_file")
printf 'network/language_server/remote_port = %s\n' "$port" \
  >"$settings/editor_settings-4.6.tres"

fixture="$(lem-yath_lisp_string "$here/scripts/gdscript-fixture.lisp")"
export LEM_YATH_GDSCRIPT_TEST_PHASE=connected
lem_start "$session" "$project/player.gd" --eval "(load #P$fixture)"

failed=0
pass() { printf 'PASS  %-27s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-27s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  sed -n '1,120p' "$LEM_YATH_GDSCRIPT_TEST_EVENTS" 2>/dev/null || true
  sed -n '1,80p' "$LEM_YATH_GDSCRIPT_TEST_REPORT" 2>/dev/null || true
}

wait_file_pattern() {
  local file=$1 pattern=$2 timeout=${3:-20} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$file" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

invoke_report() {
  lem_keys "$session" Escape
  sleep 0.15
  lem_keys "$session" Escape
  sleep 0.15
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l lem-yath-gdscript-test-report
  lem_keys "$session" Enter
}

if lem_wait_for "$session" 'NORMAL' 60 >/dev/null; then
  pass boot 'configured Lem opened the GDScript fixture'
else
  fail boot 'configured Lem did not reach normal state'
fi

if wait_file_pattern "$LEM_YATH_GDSCRIPT_TEST_EVENTS" \
     "^INITIALIZE.*root_path=${project}/([[:space:]]|$)" 30 &&
   wait_file_pattern "$LEM_YATH_GDSCRIPT_TEST_EVENTS" \
     '^DID_OPEN.*language_id=gdscript([[:space:]]|$)' 30; then
  pass tcp-workspace 'Godot TCP server initialized and received gdscript didOpen'
else
  fail tcp-workspace 'external TCP workspace did not initialize correctly'
fi

expected="STATE phase=connected mode=GDSCRIPT-MODE programming=yes tabs=yes width=4 comment=# grammar=gdscript function-face=SYNTAX-FUNCTION-NAME-ATTRIBUTE spec=LEM-YATH-GDSCRIPT-SPEC connection=TCP command=NIL configured-port=${port} default-port=6005 lsp=yes workspace=yes state=READY client=TCP-CLIENT child=no root=${project}/"
if invoke_report &&
   wait_file_pattern "$LEM_YATH_GDSCRIPT_TEST_REPORT" "^${expected}$" 15; then
  pass editor-state 'mode, parser, port, root, and external-client ownership match'
else
  fail editor-state 'configured GDScript editor state diverged'
fi

lem_stop "$session" || true
for _index in {1..80}; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if kill -0 "$server_pid" 2>/dev/null; then
  kill "$server_pid" 2>/dev/null || true
fi
wait "$server_pid" 2>/dev/null || true
server_pid=""

missing_port=$(python3 -c \
  'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
printf 'network/language_server/remote_port = %s\n' "$missing_port" \
  >"$settings/editor_settings-4.6.tres"
export LEM_YATH_GDSCRIPT_TEST_PHASE=missing
lem_start "$session" "$project/player.gd" --eval "(load #P$fixture)"

if lem_wait_for "$session" 'NORMAL' 60 >/dev/null &&
   lem_wait_for "$session" 'LSP initialization failed' 20 >/dev/null &&
   invoke_report &&
   wait_file_pattern "$LEM_YATH_GDSCRIPT_TEST_REPORT" \
     '^STATE phase=missing mode=GDSCRIPT-MODE .* lsp=no workspace=no state=none client=none child=no root=none$' 15 &&
   tmux_cmd has-session -t "$session" 2>/dev/null; then
  pass unavailable-server 'connection refusal leaves the editor and mode usable'
else
  fail unavailable-server 'connection refusal damaged the editor session'
fi

if ((failed)); then
  exit 1
fi
printf 'SUMMARY PASS failures=0\n'
