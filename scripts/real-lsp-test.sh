#!/usr/bin/env bash
# Real-ncurses integration against the language servers shipped by the
# installed lem-yath wrapper.  Servers run sequentially to keep peak load low.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-real-lsp-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-real-lsp.XXXXXX")"
case "$root" in
  "" | /)
    echo "Refusing unsafe real-LSP test directory: $root" >&2
    exit 1
    ;;
esac

session="lem-yath-real-lsp-$id"
declare -A active_pids=()

cleanup() {
  lem_stop "$session" || true
  local pid
  for pid in "${active_pids[@]-}"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  sleep 0.1
  for pid in "${active_pids[@]-}"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export LEM_HOME="$root/lem-home/"
export LEM_YATH_REAL_LSP_EXPECTED_LEM_HOME="$LEM_HOME"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_REAL_LSP_FIXTURES="$root/fixtures/"
export LEM_YATH_REAL_LSP_REPORT="$root/report"
export LEM_YATH_REAL_LSP_LOG="$root/lem.log"
export LEM_YATH_LSP_STDERR="$root/language-servers.log"

if [ -z "${LEM_YATH_REAL_LSP_NIXPKGS_SOURCE:-}" ] ||
   [ ! -d "$LEM_YATH_REAL_LSP_NIXPKGS_SOURCE" ]; then
  echo 'LEM_YATH_REAL_LSP_NIXPKGS_SOURCE must name the pinned nixpkgs source.' >&2
  exit 1
fi

mkdir -p "$HOME" "$LEM_HOME" "$XDG_CACHE_HOME" "$WORKDIR" \
  "$HOME/proj/nix" \
  "$LEM_YATH_REAL_LSP_FIXTURES/rust/src" \
  "$LEM_YATH_REAL_LSP_FIXTURES/python" \
  "$LEM_YATH_REAL_LSP_FIXTURES/markdown/.git" \
  "$LEM_YATH_REAL_LSP_FIXTURES/nix" \
  "$LEM_YATH_REAL_LSP_FIXTURES/go" \
  "$LEM_YATH_REAL_LSP_FIXTURES/terraform/.git"
ln -s "$LEM_YATH_REAL_LSP_FIXTURES/nix" "$HOME/proj/nix/computer"
: >"$LEM_YATH_REAL_LSP_REPORT"

printf '%s\n' \
  '[package]' \
  'name = "lem_yath_lsp_fixture"' \
  'version = "0.1.0"' \
  'edition = "2021"' \
  >"$LEM_YATH_REAL_LSP_FIXTURES/rust/Cargo.toml"
printf '%s\n' 'fn main() {}' \
  >"$LEM_YATH_REAL_LSP_FIXTURES/rust/src/main.rs"

printf '%s\n' \
  '[project]' \
  'name = "lem-yath-lsp-fixture"' \
  'version = "0.1.0"' \
  >"$LEM_YATH_REAL_LSP_FIXTURES/python/pyproject.toml"
printf '%s\n' 'value: int = 1' \
  >"$LEM_YATH_REAL_LSP_FIXTURES/python/main.py"

printf '%s\n' '# Real LSP fixture' '' 'This sentence is deliberately small.' \
  >"$LEM_YATH_REAL_LSP_FIXTURES/markdown/README.md"
printf '%s\n' '{ }' >"$LEM_YATH_REAL_LSP_FIXTURES/nix/default.nix"
printf '%s\n' \
  '{' \
  "  inputs.nixpkgs.url = \"path:${LEM_YATH_REAL_LSP_NIXPKGS_SOURCE}\";" \
  '  outputs = { self, nixpkgs }: {' \
  '    nixosConfigurations.nova.options = { };' \
  '    homeConfigurations.yanni.options = { };' \
  '  };' \
  '}' \
  >"$LEM_YATH_REAL_LSP_FIXTURES/nix/flake.nix"

printf '%s\n' 'module example.com/lem-yath-lsp-fixture' '' 'go 1.25' \
  >"$LEM_YATH_REAL_LSP_FIXTURES/go/go.mod"
printf '%s\n' 'package main' '' 'func main() {}' \
  >"$LEM_YATH_REAL_LSP_FIXTURES/go/main.go"

printf '%s\n' \
  'terraform {' \
  '  required_version = ">= 1.0"' \
  '}' \
  >"$LEM_YATH_REAL_LSP_FIXTURES/terraform/main.tf"

required_programs=(
  "LEM_YATH_REAL_LSP_RUST_ANALYZER:rust-analyzer"
  "LEM_YATH_REAL_LSP_PYRIGHT:pyright-langserver"
  "LEM_YATH_REAL_LSP_HARPER:harper-ls"
  "LEM_YATH_REAL_LSP_NIXD:nixd"
  "LEM_YATH_REAL_LSP_GOPLS:gopls"
  "LEM_YATH_REAL_LSP_TERRAFORM_LS:terraform-ls"
  "LEM_YATH_REAL_LSP_CARGO:cargo"
  "LEM_YATH_REAL_LSP_RUSTC:rustc"
  "LEM_YATH_REAL_LSP_CARGO_CLIPPY:cargo-clippy"
)

for entry in "${required_programs[@]}"; do
  variable=${entry%%:*}
  program=${entry#*:}
  value=${!variable:-}
  if [ -z "$value" ] || [ ! -x "$value" ]; then
    echo "$variable must name the exact executable $program." >&2
    exit 1
  fi
done

set +e
failed=0
aborted=0

pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  if [ -s "$LEM_YATH_REAL_LSP_REPORT" ]; then
    printf '%s\n' 'Real-LSP report:'
    tail -80 "$LEM_YATH_REAL_LSP_REPORT"
  fi
  if [ -s "$LEM_YATH_REAL_LSP_LOG" ]; then
    printf '%s\n' 'Lem log:'
    tail -80 "$LEM_YATH_REAL_LSP_LOG"
  fi
  if [ -s "$LEM_YATH_LSP_STDERR" ]; then
    printf '%s\n' 'Language-server stderr:'
    tail -80 "$LEM_YATH_LSP_STDERR"
  fi
}

report_line() {
  grep -E "$1" "$LEM_YATH_REAL_LSP_REPORT" 2>/dev/null | tail -1
}

wait_report() {
  local pattern=$1 timeout=${2:-20} index=0 line
  while ((index < timeout * 4)); do
    line=$(report_line "$pattern")
    if [ -n "$line" ]; then
      printf '%s\n' "$line"
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_case_outcome() {
  local case_id=$1 timeout=${2:-120}
  wait_report \
    "^(READY id=${case_id} |FAIL id=${case_id} phase=(start|initialize|ready) )" \
    "$timeout"
}

wait_pid_dead() {
  local pid=$1 timeout=${2:-15} index=0
  while ((index < timeout * 4)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_session_dead() {
  local timeout=${1:-20} index=0
  while ((index < timeout * 4)); do
    if ! tmux_cmd has-session -t "$session" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

invoke_mx() {
  local command=$1
  lem_keys "$session" Escape
  sleep 0.15
  lem_keys "$session" Escape
  sleep 0.15
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.4
  lem_keys "$session" Enter
  sleep 0.2
  lem_keys "$session" Enter
}

fixture="$(lem-yath_lisp_string "$here/scripts/real-lsp-fixture.lisp")"
startup_file="$LEM_YATH_REAL_LSP_FIXTURES/rust/src/main.rs"
expected_fixture_state='FIXTURE ready=yes boot=yes cases=6 command-line-file=yes command-line-workspace=yes lem-home=yes caller-evals=yes'

# LEM_BIN must be the installed lem-yath wrapper.  It loads its own immutable
# configuration before this test fixture; loading the repository init here
# would accidentally test a second, local configuration instead.
lem_start "$session" \
  --log-filename "$LEM_YATH_REAL_LSP_LOG" \
  --eval '(setf (uiop:getenv "LEM_YATH_REAL_LSP_EVAL_ONE") "yes")' \
  --eval "(load #P$fixture)" \
  "$startup_file"

if lem_wait_for "$session" 'NORMAL' 60 >/dev/null &&
   fixture_state=$(wait_report '^FIXTURE ' 60) &&
   [[ "$fixture_state" == "$expected_fixture_state" ]]; then
  pass boot 'configuration preceded the command-line file and caller eval'
else
  fail boot 'installed wrapper or fixture did not become ready'
  aborted=1
fi

if (( ! aborted )); then
  for entry in "${required_programs[@]}"; do
    program=${entry#*:}
    prerequisite=$(report_line "^PREREQ name=${program} ")
    if [[ "$prerequisite" == *' ok=yes '* ]]; then
      pass "path-$program" 'wrapper resolves the exact packaged executable'
    else
      fail "path-$program" "unexpected wrapper resolution: ${prerequisite:-missing}"
      aborted=1
    fi
  done
fi

for case_id in rust python nix markdown go terraform; do
  if ((aborted)); then
    break
  fi

  if ! invoke_mx lem-yath-test-real-lsp-start-next; then
    fail "$case_id-start" 'could not invoke the fixture start command'
    aborted=1
    break
  fi

  start_state=$(wait_report "^START id=${case_id} " 15)
  if [ -z "$start_state" ]; then
    outcome=$(report_line "^FAIL id=${case_id} phase=start ")
    fail "$case_id-start" "server process did not start: ${outcome:-no report}"
    aborted=1
    break
  fi

  pid=$(sed -E 's/^.* pid=([0-9]+).*$/\1/' <<<"$start_state")
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    fail "$case_id-pid" "invalid server PID in: $start_state"
    aborted=1
    break
  fi
  active_pids[$case_id]=$pid

  case_timeout=120
  outcome=$(wait_case_outcome "$case_id" "$case_timeout")
  if [ -z "$outcome" ]; then
    fail "$case_id-ready" \
      "real server did not initialize within ${case_timeout} seconds"
    aborted=1
    break
  elif [[ "$outcome" == READY* && "$outcome" == *' ok=yes '* ]]; then
    pass "$case_id-ready" 'mode, spec, root, protocol state, and client are ready'
  else
    fail "$case_id-ready" "unexpected readiness state: $outcome"
    if [[ "$outcome" == FAIL* ]]; then
      aborted=1
      break
    fi
  fi

  ready_pid=$(sed -E 's/^.* pid=([0-9]+).*$/\1/' <<<"$outcome")
  if [ "$ready_pid" != "$pid" ]; then
    fail "$case_id-pid" "server PID changed between start and ready: $pid -> $ready_pid"
  fi

  # Keep the real server alive past initialization so an immediate post-ready
  # crash cannot be mistaken for the PID death caused by explicit shutdown.
  sleep 1
  if ! invoke_mx lem-yath-test-real-lsp-record-stable; then
    fail "$case_id-stable" 'could not inspect post-initialize server health'
    aborted=1
    break
  fi

  stable_state=$(wait_report "^STABLE id=${case_id} " 15)
  if [[ "$stable_state" == *' ok=yes '* &&
        "$stable_state" == *' state=READY client-alive=yes '* ]]; then
    pass "$case_id-stable" 'server remained live after initialization'
  else
    fail "$case_id-stable" "unexpected post-initialize state: ${stable_state:-missing}"
    aborted=1
    break
  fi

  if ! invoke_mx lsp-shutdown-server; then
    fail "$case_id-shutdown" 'could not invoke the real shutdown command'
    aborted=1
    break
  fi

  if wait_pid_dead "$pid" 15; then
    unset 'active_pids[$case_id]'
  else
    fail "$case_id-process" "server PID $pid survived explicit shutdown"
    aborted=1
    break
  fi

  if ! invoke_mx lem-yath-test-real-lsp-record-shutdown; then
    fail "$case_id-shutdown" 'could not inspect post-shutdown editor state'
    aborted=1
    break
  fi

  shutdown_state=$(wait_report "^SHUTDOWN id=${case_id} " 15)
  if [[ "$shutdown_state" == *' ok=yes '* &&
        "$shutdown_state" == *' state=DISPOSED '* &&
        "$shutdown_state" == *' owned=no lsp=no registered=no '* ]]; then
    pass "$case_id-shutdown" 'workspace disposed, ownership cleared, and PID exited'
  else
    fail "$case_id-shutdown" "unexpected disposed state: ${shutdown_state:-missing}"
    aborted=1
    break
  fi
done

if (( ! aborted )); then
  if invoke_mx exit-lem && wait_session_dead 30; then
    pass exit 'normal editor exit completed with no active LSP workspace'
  else
    fail exit 'configured Lem did not exit cleanly'
  fi
fi

if ((failed)); then
  exit 1
fi

printf 'All installed real-language-server checks passed.\n'
