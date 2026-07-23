#!/usr/bin/env bash
# Sourceable tmux driver for testing Lem's TUI.
# Conventions: one tmux session per test, 200x50 pane, all output via capture-pane.

LEM_YATH_ROOT="${LEM_YATH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LEM_YATH_SOURCE="${LEM_YATH_SOURCE:-$LEM_YATH_ROOT/lem-yath}"
export LEM_YATH_OPENROUTER_MODEL_REFRESH="${LEM_YATH_OPENROUTER_MODEL_REFRESH:-0}"
export LEM_YATH_CODEX_MODEL_REFRESH="${LEM_YATH_CODEX_MODEL_REFRESH:-0}"
TMUX_BIN="${TMUX_BIN:-tmux}"
TMUX_SOCKET="${TMUX_SOCKET:-lem-yath-${LEM_YATH_CHECK_ID:-$$}}"

if [ -z "${LEM_BIN:-}" ]; then
  if command -v lem >/dev/null 2>&1; then
    LEM_BIN="$(command -v lem)"
  elif [ -x "$LEM_YATH_ROOT/result-lem/bin/lem" ]; then
    LEM_BIN="$LEM_YATH_ROOT/result-lem/bin/lem"
  else
    LEM_BIN=""
  fi
fi

lem-yath_lisp_string() {
  local value="${1//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

lem-yath_load_form() {
  printf '(load #P%s)' "$(lem-yath_lisp_string "$LEM_YATH_SOURCE/init.lisp")"
}

lem-yath_with_loaded_form() {
  printf '(progn %s %s)' "$(lem-yath_load_form)" "$1"
}

lem-yath_configure_asdf_output() {
  local cache_home source_key
  cache_home="${XDG_CACHE_HOME:-${HOME:-${TMPDIR:-/tmp}}/.cache}"
  # Nix store sources all have normalized timestamps.  Namespace compiled
  # output by source path so a new flake source cannot reuse an older FASL.
  source_key=$(printf '%s' "$LEM_YATH_SOURCE" | sha256sum | cut -c1-16)
  LEM_YATH_ASDF_CACHE="${LEM_YATH_ASDF_CACHE:-$cache_home/lem-yath/asdf/$source_key}"
  mkdir -p "$LEM_YATH_ASDF_CACHE"
  export ASDF_OUTPUT_TRANSLATIONS="$LEM_YATH_SOURCE:$LEM_YATH_ASDF_CACHE:/nix/store:/nix/store${ASDF_OUTPUT_TRANSLATIONS:+:$ASDF_OUTPUT_TRANSLATIONS}"
}

lem-yath_configure_asdf_output

tmux_cmd() {
  "$TMUX_BIN" -L "$TMUX_SOCKET" "$@"
}

lem_start() { # lem_start <session> [lem-args...]
  local s="$1"; shift
  if [ -z "$LEM_BIN" ]; then
    echo "LEM_BIN is not set and no lem executable was found on PATH" >&2
    return 127
  fi
  tmux_cmd kill-session -t "$s" 2>/dev/null || true
  local command width="${LEM_TUI_WIDTH:-200}" height="${LEM_TUI_HEIGHT:-50}"
  printf -v command "%q " "$LEM_BIN" "$@"
  tmux_cmd new-session -d -s "$s" -x "$width" -y "$height" "$command"
}

lem_start_lem-yath() { # lem_start_lem-yath <session> [lem-args...]
  local s="$1"; shift
  lem_start "$s" --eval "$(lem-yath_load_form)" "$@"
}

lem_start_lem-yath_eval() { # lem_start_lem-yath_eval <session> <form> [lem-args...]
  local s="$1" form="$2"; shift 2
  lem_start "$s" --eval "$(lem-yath_with_loaded_form "$form")" "$@"
}

lem_keys() { # lem_keys <session> <tmux-send-keys args...>
  local s="$1"; shift
  tmux_cmd send-keys -t "$s" "$@"
}

lem_capture() { # lem_capture <session>
  tmux_cmd capture-pane -t "$1" -p
}

lem_wait_for() { # lem_wait_for <session> <grep-ERE> [timeout-sec=10]
  local s="$1" pat="$2" timeout="${3:-10}" i=0
  while (( i < timeout * 4 )); do
    if lem_capture "$s" | grep -qE "$pat"; then return 0; fi
    sleep 0.25; i=$((i + 1))
  done
  echo "TIMEOUT waiting for /$pat/ in session $s; screen was:" >&2
  lem_capture "$s" >&2
  return 1
}

lem_stop() { # lem_stop <session>
  tmux_cmd kill-session -t "$1" 2>/dev/null
}
