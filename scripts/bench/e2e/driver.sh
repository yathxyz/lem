#!/usr/bin/env bash
# driver.sh -- sourceable tmux driver for the T3 end-to-end harness
# (SPEC-PERF PF-7).  Self-contained: no dependency on the lem-yath repo, whose
# tui-driver.sh pattern this borrows (private socket, sandboxed HOME/XDG, fixed
# pane, capture-pane assertions, cleanup trap killing only its own session).
#
# SAFETY (SPEC-PERF Constraint 7 -- the user runs many lem instances and tmux
# sessions): every run uses a UNIQUE PRIVATE tmux socket (`tmux -L <uniq>'),
# NEVER the default server, and the cleanup trap kills only the server on that
# private socket and removes only its own mktemp sandbox.  The editor under test
# runs with HOME/XDG_*/LEM_HOME redirected into the sandbox, so it reads and
# writes NOTHING of the user's real config, and (lem-home) resolves inside the
# sandbox -- so the metrics dump on exit lands in the test root.
#
# Source this file, then call `lem_e2e_init' once (creates the sandbox + socket
# and installs the trap).  Primitives:
#
#   lem_start   <session> <eval-form> [files...]   launch ./lem in a 200x50 pane
#   lem_keys    <session> <key> [key...]           tmux send-keys (named keys)
#   lem_type    <session> <literal-string>         tmux send-keys -l
#   lem_capture <session>                          capture-pane -p to stdout
#   lem_wait_for <session> <needle> [timeout_s]    poll capture until needle seen
#   lem_alive   <session>                          0 if the session still exists
#   lem_stop    <session> [timeout_s]              C-x C-c (+ y) then wait for exit
#   lem_metrics_json                               newest dump under LEM_HOME/metrics
#
# The editor starts with metrics recording ON (the default `record-metrics'
# editor variable), so the exit dump captures the driven keystrokes.

set -euo pipefail

# --- configuration (env-overridable) ----------------------------------------
E2E_PANE_W="${E2E_PANE_W:-200}"
E2E_PANE_H="${E2E_PANE_H:-50}"
: "${LEM_BIN:=}"

# Resolve the repo root from this file's location (scripts/bench/e2e -> root).
E2E_DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_REPO_ROOT="$(cd "$E2E_DRIVER_DIR/../../.." && pwd)"

# --- lifecycle --------------------------------------------------------------

lem_e2e_init() {
  # Resolve the binary (repo ./lem unless LEM_BIN overrides).
  if [ -z "$LEM_BIN" ]; then
    LEM_BIN="$E2E_REPO_ROOT/lem"
  fi
  if [ ! -x "$LEM_BIN" ]; then
    echo "driver: lem binary not found/executable at $LEM_BIN (build with 'make ncurses')" >&2
    return 1
  fi

  # Unique private socket -- never the default tmux server (Constraint 7).
  LEM_SOCK="lem-e2e-$$-${RANDOM}${RANDOM}"

  # Sandbox root: everything the editor reads/writes is redirected here.
  LEM_E2E_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lem-e2e.XXXXXX")"
  export HOME="$LEM_E2E_ROOT/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_DATA_HOME="$HOME/.local/share"
  export XDG_STATE_HOME="$HOME/.local/state"
  export XDG_CACHE_HOME="$HOME/.cache"
  # Trailing slash is REQUIRED: (lem-home) feeds LEM_HOME to merge-pathnames,
  # which strips a final non-directory component -- without the slash the
  # metrics dump lands in the PARENT of lem-home.  (Verified: PF-7 bring-up.)
  export LEM_HOME="$LEM_E2E_ROOT/lem-home/"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" \
           "$XDG_CACHE_HOME" "$LEM_HOME"

  trap 'lem_e2e_cleanup' EXIT INT TERM
}

lem_e2e_cleanup() {
  # Kill ONLY our private-socket server (never the default), then the sandbox.
  if [ -n "${LEM_SOCK:-}" ]; then
    tmux -L "$LEM_SOCK" kill-server 2>/dev/null || true
    # tmux auto-exits when its last session closes and does not always unlink
    # the socket; remove our own stale socket file so runs don't accumulate
    # them.  Only ever touches OUR uniquely-named socket.
    rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$LEM_SOCK" 2>/dev/null || true
  fi
  if [ -n "${LEM_E2E_ROOT:-}" ] && [ -d "$LEM_E2E_ROOT" ]; then
    rm -rf "$LEM_E2E_ROOT"
  fi
}

# --- primitives -------------------------------------------------------------

# Launch ./lem in a fresh 200x50 pane on our private socket.  A generated
# launcher script carries the exact argv (printf %q, so the eval form's parens
# and quotes never fight tmux's command parsing) and re-exports the sandbox
# env, so the editor is isolated regardless of the tmux server's environment.
lem_start() {
  local session="$1"; shift
  local evalform="$1"; shift
  local launcher="$LEM_E2E_ROOT/launch-$session.sh"
  {
    printf '#!/usr/bin/env bash\n'
    local v
    for v in HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME LEM_HOME; do
      printf 'export %s=%q\n' "$v" "${!v}"
    done
    printf 'exec %q -e %q' "$LEM_BIN" "$evalform"
    local f
    for f in "$@"; do printf ' %q' "$f"; done
    printf '\n'
  } > "$launcher"
  chmod +x "$launcher"
  tmux -L "$LEM_SOCK" new-session -d -s "$session" \
       -x "$E2E_PANE_W" -y "$E2E_PANE_H" "$launcher"
}

lem_keys() {
  local session="$1"; shift
  tmux -L "$LEM_SOCK" send-keys -t "$session" "$@"
}

lem_type() {
  local session="$1"; shift
  tmux -L "$LEM_SOCK" send-keys -t "$session" -l "$1"
}

lem_capture() {
  tmux -L "$LEM_SOCK" capture-pane -p -t "$1" 2>/dev/null || true
}

lem_alive() {
  tmux -L "$LEM_SOCK" has-session -t "$1" 2>/dev/null
}

# Poll capture-pane until NEEDLE appears (fixed-string).  Returns 0 on success,
# 1 on timeout (default 15s).
lem_wait_for() {
  local session="$1" needle="$2" timeout="${3:-15}"
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if lem_capture "$session" | grep -qF -- "$needle"; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

# Exit the editor cleanly so the metrics dump fires.  C-x C-c is exit-lem; a
# file-backed modified buffer prompts "Leave anyway? [y/n]" -- the `y' answers
# it, and is harmless when no prompt appears (a scratch buffer exits at once).
lem_stop() {
  local session="$1" timeout="${2:-10}"
  local deadline=$(( $(date +%s) + timeout ))
  lem_keys "$session" C-x C-c 2>/dev/null || true
  sleep 0.3
  lem_keys "$session" y 2>/dev/null || true
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! lem_alive "$session"; then
      return 0
    fi
    lem_keys "$session" y 2>/dev/null || true
    sleep 0.2
  done
  # Last resort: the metrics dump only fires on a clean exit, so a hung session
  # is a harness failure the caller must see.
  return 1
}

# Path of the newest metrics dump in the sandbox (empty if none yet).
lem_metrics_json() {
  ls -t "$LEM_HOME"metrics/*.json 2>/dev/null | head -1 || true
}
