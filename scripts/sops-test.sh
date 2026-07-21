#!/usr/bin/env bash
# Real-ncurses coverage for transparent SOPS editing and failure recovery.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-sops-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-sops.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export LEM_YATH_COMPLETION_STATE_FILE="$root/completion-ranking.sexp"
export LEM_YATH_SOPS_CONTROL="$root/control"
export LEM_YATH_SOPS_REPORT="$root/report"
export LEM_YATH_SOPS_FAILED_FILE="$WORKDIR/failed.yaml"
export LEM_YATH_SOPS_PLAIN_FILE="$WORKDIR/plain.yaml"
export LEM_YATH_SOPS_CREATE_FILE="$WORKDIR/created.yaml"
export LEM_YATH_SOPS_CREATE_FAILURE_FILE="$WORKDIR/create-failure.env"
export LEM_YATH_SOPS_MISSING_PARENT_FILE="$WORKDIR/missing/secret.yaml"
export LEM_YATH_SOPS_MISSING_POLICY_FILE="$root/no-policy/secret.yaml"
export LEM_YATH_SOPS_OLD_VERSION_FILE="$WORKDIR/old-version.yaml"
export LEM_YATH_SOPS_MALFORMED_VERSION_FILE="$WORKDIR/malformed-version.yaml"
export LEM_YATH_SOPS_PREFLIGHT_REPORT="$root/preflight-report"
export LEM_YATH_SOPS_SOURCE="${LEM_YATH_SOPS_SOURCE:-${LEM_YATH_SOURCE:-$here/lem-yath}/src/sops.lisp}"
mkdir -p "$HOME" "$WORKDIR/roam" "$root/bin" "$root/no-policy"
: > "$WORKDIR/.sops.yaml"
cp "$here/scripts/sops-fake.sh" "$root/bin/sops"
chmod +x "$root/bin/sops"
export LEM_YATH_SOPS_PROGRAM="$(command -v bash)"
export LEM_YATH_SOPS_PROGRAM_ARGUMENT="$root/bin/sops"
export PATH="$root/bin:$PATH"
cp "$here/scripts/sops-secret.yaml" "$WORKDIR/secret.yaml"
cp "$here/scripts/sops-failed.yaml" "$LEM_YATH_SOPS_FAILED_FILE"
cp "$here/scripts/sops-plain.yaml" "$LEM_YATH_SOPS_PLAIN_FILE"
chmod u+w "$WORKDIR/secret.yaml" "$LEM_YATH_SOPS_FAILED_FILE" "$LEM_YATH_SOPS_PLAIN_FILE"

source "$here/scripts/tui-driver.sh"

session="lem-yath-sops-$id"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %-26s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-26s %s\n' "$1" "$2"
  [ -n "${3:-}" ] && lem_capture "$3" 2>/dev/null || true
}

enter_normal() {
  lem_keys "$session" Escape
  sleep 0.4
}

append_line() {
  local text=$1
  enter_normal
  lem_keys "$session" G
  sleep 0.2
  lem_keys "$session" o
  lem_wait_for "$session" 'INSERT' 10 >/dev/null
  tmux_cmd send-keys -t "$session" -l "$text"
  sleep 0.3
}

save_current() {
  enter_normal
  lem_keys "$session" C-x C-s
  sleep 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/sops-fixture.lisp")"
if lem_start_lem-yath_eval "$session" "(load #P$fixture)" \
    "$WORKDIR/secret.yaml" \
    && lem_wait_for "$session" 'ZYZZYVA-PLAINTEXT' 30 >/dev/null; then
  pass boot 'encrypted YAML opened as plaintext'
else
  [ -f "$LEM_YATH_SOPS_REPORT" ] && sed -n '1p' "$LEM_YATH_SOPS_REPORT" >&2
  fail boot 'configured Lem did not decrypt the fixture' "$session"
fi

lem_keys "$session" F5
if lem_wait_for "$session" 'SOPS-STATE active=yes creating=no failed=no readonly=no modified=no' 10 >/dev/null; then
  pass activation 'the decrypted buffer is writable and clean'
else
  fail activation 'SOPS buffer state was not activated safely' "$session"
fi

append_line 'EDITED-SOPS'
save_current
if grep -q 'ciphertext: EDITED' "$WORKDIR/secret.yaml" \
    && grep -q 'trailing-preserved: yes' "$WORKDIR/secret.yaml" \
    && ! grep -q 'ZYZZYVA-PLAINTEXT\|EDITED-SOPS\|trailing: keep' "$WORKDIR/secret.yaml" \
    && lem_capture "$session" | grep -q 'ZYZZYVA-PLAINTEXT'; then
  pass encrypted-save 'save wrote ciphertext, retained plaintext, and skipped formatting'
else
  sed -n '1,8p' "$WORKDIR/secret.yaml" >&2
  fail encrypted-save 'save leaked plaintext or changed the live buffer' "$session"
fi

before_failure=$(sha256sum "$WORKDIR/secret.yaml" | cut -d' ' -f1)
enter_normal
lem_keys "$session" F6
lem_wait_for "$session" 'SOPS-CONTROL encrypt-fail' 10 >/dev/null
control_state=$(sed -n '1p' "$LEM_YATH_SOPS_CONTROL")
append_line 'FAILURE-RETAINED'
save_current
after_failure=$(sha256sum "$WORKDIR/secret.yaml" | cut -d' ' -f1)
lem_keys "$session" F5
sleep 0.5
state=$(sed -n '1p' "$LEM_YATH_SOPS_REPORT")
if [[ $before_failure == "$after_failure" ]] \
    && [[ $control_state == encrypt-fail ]] \
    && grep -q 'active=T.*creating=NIL.*failed=NIL.*readonly=NIL.*modified=T' <<<"$state" \
    && ! lem_capture "$session" | grep -q 'ZYZZYVA-SOPS-ERROR-MUST-NOT-RENDER'; then
  pass encrypt-failure 'failed encryption preserved disk and editable plaintext without stderr leakage'
else
  printf 'control=%s before=%s after=%s state=%s\n' \
    "$control_state" "$before_failure" "$after_failure" "$state" >&2
  fail encrypt-failure 'failed encryption corrupted state or exposed stderr' "$session"
fi

lem_keys "$session" F7
lem_wait_for "$session" 'SOPS-CONTROL clear' 10 >/dev/null
save_current
if grep -q 'ciphertext: RECOVERED' "$WORKDIR/secret.yaml" \
    && grep -q 'trailing-preserved: yes' "$WORKDIR/secret.yaml"; then
  pass encrypt-retry 'a later save encrypted the retained edits'
else
  fail encrypt-retry 'save did not recover after encryption failure' "$session"
fi

enter_normal
lem_keys "$session" F8
if lem_wait_for "$session" 'SECOND-SECRET' 10 >/dev/null \
    && lem_wait_for "$session" 'SOPS-EXTERNAL-REVERT' 10 >/dev/null; then
  pass revert 'revert re-read external ciphertext as clean plaintext'
else
  fail revert 'SOPS-aware revert did not refresh the buffer' "$session"
fi

enter_normal
lem_keys "$session" F3
if lem_wait_for "$session" 'SOPS-STATE active=no creating=no failed=yes readonly=yes modified=no' 10 >/dev/null \
    && ! lem_capture "$session" | grep -q 'ZYZZYVA-SOPS-ERROR-MUST-NOT-RENDER'; then
  pass decrypt-failure 'failed decryption left ciphertext read-only without stderr leakage'
else
  fail decrypt-failure 'failed decryption was not fail-closed' "$session"
fi

enter_normal
lem_keys "$session" F2
if lem_wait_for "$session" 'RECOVERED-SECRET' 10 >/dev/null \
    && lem_wait_for "$session" 'SOPS-RETRY active=yes readonly=no' 10 >/dev/null; then
  pass decrypt-retry 'revert retried decryption and restored editing'
else
  fail decrypt-retry 'decryption retry did not recover the buffer' "$session"
fi

enter_normal
lem_keys "$session" F1
if lem_wait_for "$session" 'SOPS-STATE active=no creating=no failed=no readonly=no modified=no' 10 >/dev/null \
    && lem_capture "$session" | grep -q 'ordinary: plaintext'; then
  pass plaintext 'ordinary matching files remain ordinary buffers'
else
  fail plaintext 'prefiltered plaintext file was intercepted' "$session"
fi

enter_normal
lem_keys "$session" F11
if lem_wait_for "$session" 'SOPS-PREFLIGHT templates=yes missing-parent=yes missing-policy=yes directory=yes old-version=yes malformed-version=yes' 10 >/dev/null \
    && grep -q 'templates=T missing-parent=T missing-policy=T directory=T old-version=T malformed-version=T' "$LEM_YATH_SOPS_PREFLIGHT_REPORT"; then
  pass creation-preflight 'templates match and invalid creation fails before mutation'
else
  [ -f "$LEM_YATH_SOPS_PREFLIGHT_REPORT" ] && sed -n '1p' "$LEM_YATH_SOPS_PREFLIGHT_REPORT" >&2
  fail creation-preflight 'creation validation mutated editor or filesystem state' "$session"
fi

enter_normal
lem_keys "$session" M-x
tmux_cmd send-keys -t "$session" -l 'sops-find-file'
lem_keys "$session" Enter
if lem_wait_for "$session" 'Find SOPS file:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l "$LEM_YATH_SOPS_CREATE_FILE"
  lem_keys "$session" Enter
fi
if lem_wait_for "$session" 'Welcome to SOPS!' 10 >/dev/null; then
  lem_keys "$session" F5
  sleep 0.5
  state=$(sed -n '1p' "$LEM_YATH_SOPS_REPORT")
  if grep -q 'active=T.*creating=T.*failed=NIL.*readonly=NIL.*modified=NIL' <<<"$state" \
      && [[ ! -e $LEM_YATH_SOPS_CREATE_FILE ]]; then
    pass creation-open 'M-x seeded a clean encrypted-creation buffer without touching disk'
  else
    printf 'state=%s disk=%s\n' "$state" "$([[ -e $LEM_YATH_SOPS_CREATE_FILE ]] && printf yes || printf no)" >&2
    fail creation-open 'guided creation did not preserve the clean no-disk state' "$session"
  fi
else
  fail creation-open 'M-x sops-find-file did not seed the YAML example' "$session"
fi

save_current
lem_keys "$session" F5
sleep 0.5
state=$(sed -n '1p' "$LEM_YATH_SOPS_REPORT")
if grep -q 'ciphertext: CREATED' "$LEM_YATH_SOPS_CREATE_FILE" \
    && ! grep -q 'Welcome to SOPS!' "$LEM_YATH_SOPS_CREATE_FILE" \
    && grep -q 'active=T.*creating=NIL.*failed=NIL.*readonly=NIL.*modified=NIL' <<<"$state" \
    && lem_capture "$session" | grep -q 'Welcome to SOPS!'; then
  pass creation-save 'a clean first save wrote ciphertext and transitioned in place'
else
  [ -f "$LEM_YATH_SOPS_CREATE_FILE" ] && sed -n '1,6p' "$LEM_YATH_SOPS_CREATE_FILE" >&2
  printf 'state=%s\n' "$state" >&2
  fail creation-save 'clean first save leaked plaintext or failed to transition' "$session"
fi

enter_normal
lem_keys "$session" F6
lem_wait_for "$session" 'SOPS-CONTROL encrypt-fail' 10 >/dev/null
lem_keys "$session" F10
if lem_wait_for "$session" 'SOPS-CREATE-FAILURE-OPEN' 10 >/dev/null; then
  append_line 'FIRST-SAVE-FAILURE'
  save_current
  lem_keys "$session" F5
  sleep 0.5
  state=$(sed -n '1p' "$LEM_YATH_SOPS_REPORT")
  if [[ ! -e $LEM_YATH_SOPS_CREATE_FAILURE_FILE ]] \
      && grep -q 'active=T.*creating=T.*failed=NIL.*readonly=NIL.*modified=T' <<<"$state" \
      && ! lem_capture "$session" | grep -q 'ZYZZYVA-SOPS-ERROR-MUST-NOT-RENDER'; then
    pass creation-failure 'failed first encryption retained editable plaintext and created no file'
  else
    printf 'state=%s disk=%s\n' "$state" "$([[ -e $LEM_YATH_SOPS_CREATE_FAILURE_FILE ]] && printf yes || printf no)" >&2
    fail creation-failure 'failed first encryption leaked or lost creation state' "$session"
  fi
else
  fail creation-failure 'could not open the failure-path creation buffer' "$session"
fi

lem_keys "$session" F7
lem_wait_for "$session" 'SOPS-CONTROL clear' 10 >/dev/null
save_current
if grep -q 'ciphertext: CREATE-RECOVERED' "$LEM_YATH_SOPS_CREATE_FAILURE_FILE" \
    && ! grep -q 'FIRST-SAVE-FAILURE' "$LEM_YATH_SOPS_CREATE_FAILURE_FILE"; then
  pass creation-retry 'a later first save encrypted the retained creation buffer'
else
  fail creation-retry 'creation did not recover after encryption failure' "$session"
fi

enter_normal
lem_keys "$session" F9
if lem_wait_for "$session" 'SOPS-RELOADED' 15 >/dev/null; then
  pass reload 'source reload remained idempotent'
else
  fail reload 'source reload failed' "$session"
fi

printf '\n'
if ((failed)); then
  printf 'SOPS TEST FAILED\n'
  exit 1
fi
printf 'SOPS TEST PASSED\n'
