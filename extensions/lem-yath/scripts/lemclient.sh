#!/usr/bin/env bash
# Reuse the active lem-yath ncurses process, with a visible tmux handoff.
set -euo pipefail

wait_mode='wait'
focus=1
next_line=1
next_column=0
location_pending=0
paths=()
lines=()
columns=()

usage() {
  printf 'Usage: lemclient [-n|--no-wait] [--no-focus] [+LINE[:COLUMN]] [--] [FILE ...]\n' >&2
}

while (($#)); do
  case "$1" in
    -n|--no-wait)
      wait_mode='nowait'
      shift
      ;;
    --wait)
      wait_mode='wait'
      shift
      ;;
    --no-focus)
      focus=0
      shift
      ;;
    --)
      shift
      while (($#)); do
        paths+=("$(realpath -m -s -- "$1")")
        lines+=("$next_line")
        columns+=("$next_column")
        next_line=1
        next_column=0
        location_pending=0
        shift
      done
      ;;
    +*)
      if [[ $1 =~ ^\+([0-9]+)(:([0-9]+))?$ ]]; then
        next_line=${BASH_REMATCH[1]}
        next_column=${BASH_REMATCH[3]:-0}
        location_pending=1
      else
        paths+=("$(realpath -m -s -- "$1")")
        lines+=("$next_line")
        columns+=("$next_column")
        next_line=1
        next_column=0
        location_pending=0
      fi
      shift
      ;;
    -*)
      usage
      printf 'lemclient: unsupported option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      paths+=("$(realpath -m -s -- "$1")")
      lines+=("$next_line")
      columns+=("$next_column")
      next_line=1
      next_column=0
      location_pending=0
      shift
      ;;
  esac
done

if ((location_pending)); then
  usage
  printf 'lemclient: +LINE[:COLUMN] must precede a file\n' >&2
  exit 2
fi

if ((${#paths[@]} > 64)); then
  printf 'lemclient: at most 64 files may be opened in one request\n' >&2
  exit 2
fi

cache_home=${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}
if [[ -n ${XDG_RUNTIME_DIR:-} ]]; then
  runtime_directory=$XDG_RUNTIME_DIR/lem-yath
else
  runtime_directory=$cache_home/lem-yath/runtime
fi
socket=${LEM_YATH_SERVER_SOCKET:-$runtime_directory/server.sock}
pane_file=${LEM_YATH_SERVER_PANE_FILE:-$socket.pane}

alternate_editor() {
  local alternate=${LEM_YATH_ALTERNATE_EDITOR:-}
  if [[ -z $alternate ]]; then
    local sibling
    sibling=$(cd "$(dirname "$0")" && pwd -P)/lem
    if [[ -x $sibling ]]; then
      alternate=$sibling
    else
      alternate=lem
    fi
  fi
  exec "$alternate" "${paths[@]}"
}

target_pane=
origin_pane=${TMUX_PANE:-}
if ((focus)); then
  if [[ ! -S $socket || -z ${TMUX:-} || ! -r $pane_file ]]; then
    alternate_editor
  fi
  mapfile -t pane_metadata <"$pane_file"
  target_tmux=${pane_metadata[0]:-}
  target_pane=${pane_metadata[1]:-}
  current_tmux=${TMUX%,*}
  if ((${#pane_metadata[@]} != 2)) ||
     [[ -z $target_tmux || $target_tmux != "$current_tmux" ||
        ! $target_pane =~ ^%[0-9]+$ ]] ||
     ! tmux display-message -p -t "$target_pane" '#{pane_id}' >/dev/null 2>&1; then
    alternate_editor
  fi
elif [[ ! -S $socket ]]; then
  alternate_editor
fi

response=$(mktemp "${TMPDIR:-/tmp}/lemclient-response.XXXXXX")
errors=$(mktemp "${TMPDIR:-/tmp}/lemclient-errors.XXXXXX")
transport_pid=
switched=0

restore_view() {
  if ((switched)) && [[ -n $origin_pane ]]; then
    tmux switch-client -t "$origin_pane" >/dev/null 2>&1 || true
    switched=0
  fi
}

# shellcheck disable=SC2329  # Invoked through the EXIT trap below.
cleanup() {
  local status=$?
  if [[ -n ${transport_pid:-} ]] && kill -0 "$transport_pid" 2>/dev/null; then
    kill "$transport_pid" 2>/dev/null || true
    wait "$transport_pid" 2>/dev/null || true
  fi
  restore_view
  rm -f -- "$response" "$errors"
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

send_request() {
  printf 'LEM-YATH-1\0%s\0%d\0' "$wait_mode" "${#paths[@]}"
  local index
  for ((index=0; index<${#paths[@]}; index++)); do
    printf '%s\0%s\0%s\0' \
      "${lines[index]}" "${columns[index]}" "${paths[index]}"
  done
}

(send_request | socat STDIO,ignoreeof "UNIX-CONNECT:$socket" \
  >"$response" 2>"$errors") &
transport_pid=$!

opened=0
for _ in {1..100}; do
  if grep -qx 'OPENED' "$response" 2>/dev/null; then
    opened=1
    break
  fi
  if grep -qE '^(ERROR|ABORT|DONE)( |$)' "$response" 2>/dev/null ||
     ! kill -0 "$transport_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done

if ((opened && focus)) && [[ $target_pane != "$origin_pane" ]]; then
  if tmux switch-client -t "$target_pane" >/dev/null 2>&1; then
    switched=1
  fi
fi

set +e
wait "$transport_pid"
transport_status=$?
set -e
transport_pid=
restore_view

result=$(tail -n 1 "$response" 2>/dev/null || true)
case "$result" in
  DONE)
    exit 0
    ;;
  ABORT)
    exit 1
    ;;
  ERROR*)
    printf 'lemclient: %s\n' "${result#ERROR }" >&2
    exit 2
    ;;
  *)
    if ((transport_status != 0)); then
      sed -n '1,20p' "$errors" >&2
    fi
    printf 'lemclient: server connection ended without a result\n' >&2
    exit 2
    ;;
esac
