#!/usr/bin/env bash
# Real-ncurses, real-stdio regression for project-scoped LSP lifecycle.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-lsp-project-$$}"
if ! root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-lsp-project.XXXXXX")"; then
  echo "Failed to create the LSP test directory." >&2
  exit 1
fi
case "$root" in
  "" | /)
    echo "Refusing unsafe LSP test directory: $root" >&2
    exit 1
    ;;
esac

session="lem-yath-lsp-project-$id"
cleanup() {
  lem_stop "$session" || true
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_LSP_TEST_PROJECT_A="$root/project-a/"
export LEM_YATH_LSP_TEST_PROJECT_B="$root/project-b/"
export LEM_YATH_LSP_TEST_GIT_ROOT="$root/git-root/"
export LEM_YATH_LSP_TEST_TIMEOUT_ROOT="$root/timeout-root/"
export LEM_YATH_LSP_TEST_PENDING_ROOT="$root/pending-root/"
export LEM_YATH_LSP_TEST_SLOW_ROOT="$root/slow-root/"
export LEM_YATH_LSP_TEST_EVENTS="$root/events.tsv"
export LEM_YATH_LSP_TEST_REPORT="$root/report"
export LEM_YATH_LSP_TEST_SERVER="$here/scripts/fake-lsp-server.py"
export LEM_YATH_LSP_TEST_PYTHON="${LEM_YATH_LSP_TEST_PYTHON:-$(command -v python3 || true)}"

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" \
  "$LEM_YATH_LSP_TEST_PROJECT_A" "$LEM_YATH_LSP_TEST_PROJECT_B" \
  "$LEM_YATH_LSP_TEST_PROJECT_A/.git" \
  "$LEM_YATH_LSP_TEST_PROJECT_B/.git" \
  "$LEM_YATH_LSP_TEST_GIT_ROOT/.git" \
  "$LEM_YATH_LSP_TEST_GIT_ROOT/nested" \
  "$LEM_YATH_LSP_TEST_TIMEOUT_ROOT" \
  "$LEM_YATH_LSP_TEST_PENDING_ROOT" \
  "$LEM_YATH_LSP_TEST_SLOW_ROOT"
: >"$LEM_YATH_LSP_TEST_EVENTS"
: >"$LEM_YATH_LSP_TEST_REPORT"

for project in "$LEM_YATH_LSP_TEST_PROJECT_A" "$LEM_YATH_LSP_TEST_PROJECT_B"; do
  : >"$project/.lsp-fixture-root"
  printf 'one\n' >"$project/one.fixture"
  printf 'two\n' >"$project/two.fixture"
  printf 'constant\npadding\nxxxxAlphaSymbol tail\n' >"$project/symbols.fixture"
done

printf 'idle\n' >"$LEM_YATH_LSP_TEST_PROJECT_A/idle.fixture"
printf 'peer\n' >"$LEM_YATH_LSP_TEST_PROJECT_A/peer.fixture"
printf 'constant\npadding\nxxxxPeerAlphaSymbol tail\n' \
  >"$LEM_YATH_LSP_TEST_PROJECT_A/peer-symbols.fixture"
printf 'migration target\n' \
  >"$LEM_YATH_LSP_TEST_PROJECT_B/migrated+raw.fixture"
: >"$LEM_YATH_LSP_TEST_TIMEOUT_ROOT/.lsp-timeout-root"
printf 'timeout\n' >"$LEM_YATH_LSP_TEST_TIMEOUT_ROOT/timeout.fixture"
: >"$LEM_YATH_LSP_TEST_PENDING_ROOT/.lsp-pending-root"
printf 'pending\n' >"$LEM_YATH_LSP_TEST_PENDING_ROOT/pending.fixture"
: >"$LEM_YATH_LSP_TEST_SLOW_ROOT/.lsp-slow-shutdown-root"
printf 'slow\n' >"$LEM_YATH_LSP_TEST_SLOW_ROOT/slow.fixture"

# Fixture setup must fail fast.  The interaction phase records independent
# failures so one broken behavior does not hide the rest of the report.
set +e
failed=0

pass() { printf 'PASS  %-31s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-31s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  if [ -s "$LEM_YATH_LSP_TEST_EVENTS" ]; then
    printf '%s\n' 'LSP events:'
    sed -n '1,160p' "$LEM_YATH_LSP_TEST_EVENTS"
  fi
}

report_count() {
  grep -cE "$1" "$LEM_YATH_LSP_TEST_REPORT" 2>/dev/null || true
}

wait_report_count() {
  local pattern=$1 expected=$2 timeout=${3:-15} index=0
  while ((index < timeout * 4)); do
    if (( $(report_count "$pattern") >= expected )); then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

event_count() {
  local event=$1 fragment=${2:-}
  if [ ! -f "$LEM_YATH_LSP_TEST_EVENTS" ]; then
    printf '0\n'
    return
  fi
  if [ -n "$fragment" ]; then
    grep -E "^${event}[[:space:]]" "$LEM_YATH_LSP_TEST_EVENTS" 2>/dev/null |
      grep -Fc "$fragment" || true
  else
    grep -cE "^${event}[[:space:]]" "$LEM_YATH_LSP_TEST_EVENTS" 2>/dev/null || true
  fi
}

wait_event_count() {
  local event=$1 fragment=$2 expected=$3 timeout=${4:-20} index=0
  while ((index < timeout * 4)); do
    if (( $(event_count "$event" "$fragment") >= expected )); then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

latest_event_pid() {
  local event=$1 fragment=$2
  grep -E "^${event}[[:space:]]" "$LEM_YATH_LSP_TEST_EVENTS" 2>/dev/null |
    grep -F "$fragment" |
    tail -1 |
    sed -E 's/^.*pid=([0-9]+).*$/\1/'
}

wait_pid_dead() {
  local pid=$1 timeout=${2:-20} index=0
  while ((index < timeout * 4)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

assert_event_count() {
  local name=$1 event=$2 fragment=$3 expected=$4 actual
  actual=$(event_count "$event" "$fragment")
  if [ "$actual" -eq "$expected" ]; then
    pass "$name" "$event count is $expected for ${fragment#*=}"
  else
    fail "$name" "expected $expected $event events for '$fragment', got $actual"
  fi
}

invoke_mx() {
  local command=$1 prompt=${2:-}
  lem_keys "$session" Escape
  sleep 0.15
  lem_keys "$session" Escape
  sleep 0.15
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.4
  lem_keys "$session" Enter
  if [ -n "$prompt" ]; then
    lem_wait_for "$session" "$prompt" 10 >/dev/null
  fi
}

prompt_backspace() {
  local count=$1 index=0
  while ((index < count)); do
    lem_keys "$session" BSpace
    index=$((index + 1))
  done
}

confirm_yes_prompt() {
  local pattern=$1
  lem_wait_for "$session" "$pattern" 10 >/dev/null || return 1
  lem_keys "$session" y
  sleep 0.3
}

record_workspace_state() {
  local before
  before=$(report_count '^STATE label=manual ')
  invoke_mx lem-yath-test-lsp-record-workspaces || return 1
  wait_report_count '^STATE label=manual ' "$((before + 1))"
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

if [ -z "$LEM_YATH_LSP_TEST_PYTHON" ]; then
  printf 'FAIL  %-31s %s\n' prerequisites 'python3 is required for the fake LSP server'
  exit 1
fi

fixture="$(lem-yath_lisp_string "$here/scripts/lsp-project-fixture.lisp")"
scratch="$root/scratch.txt"
: >"$scratch"
lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$scratch"

if lem_wait_for "$session" 'NORMAL' 60 >/dev/null &&
   wait_report_count '^READY$' 1 60; then
  pass boot 'configured Lem loaded the project LSP fixture'
else
  fail boot 'fixture did not become ready'
fi

if invoke_mx lem-yath-test-lsp-static-checks &&
   wait_report_count '^SUMMARY STATIC PASS failures=0$' 1; then
  pass static-contracts \
    'URI safety, Lisp-v2 resolvers, roots, guards, and bindings are sound'
else
  fail static-contracts 'one or more project LSP static contracts failed'
fi

if [ "$(event_count START '')" -eq 0 ]; then
  pass lisp-v2-no-server \
    'loading and probing Lisp-v2 resolver/restart methods launched no server'
else
  fail lisp-v2-no-server 'a static Lisp-v2 contract unexpectedly launched a server'
fi

# The initialize delay keeps the first workspace pending while the second
# buffer's mode hook runs.  Both didOpen notifications must share one process.
if invoke_mx lem-yath-test-lsp-open-project-a &&
   wait_event_count INITIALIZE "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" 1 &&
   wait_event_count DID_OPEN "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" 2; then
  assert_event_count same-root-single-server INITIALIZE \
    "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" 1
  assert_event_count same-root-both-open DID_OPEN \
    "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" 2
  assert_event_count project-server-cwd START \
    "cwd=${LEM_YATH_LSP_TEST_PROJECT_A%/}" 1
else
  fail same-root-reuse 'project A did not initialize and open both buffers'
fi


diagnostic_report_before=$(report_count '^DIAGNOSTIC phase=a ')
if wait_event_count PUBLISH_DIAGNOSTICS \
     "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" 2 &&
   invoke_mx lem-yath-test-lsp-record-project-a-diagnostics &&
   wait_report_count '^DIAGNOSTIC phase=a ' \
     "$((diagnostic_report_before + 1))"; then
  diagnostic_state=$(grep '^DIAGNOSTIC phase=a ' \
    "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  if [ "$diagnostic_state" = \
       'DIAGNOSTIC phase=a count=1 timer=yes current=yes init-timer=no spinner=no' ]; then
    pass diagnostics-live \
      'real publishDiagnostics created one owned overlay and cleared init timer'
  else
    fail diagnostics-live "unexpected diagnostic state: $diagnostic_state"
  fi
else
  fail diagnostics-live 'owned diagnostics or initialization-timer cleanup failed'
fi

if record_workspace_state; then
  state=$(grep '^STATE label=manual ' "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  if [[ "$state" == *'workspaces=1 same-a=yes isolated-b=no '* &&
        "$state" == *'a-live=2' ]]; then
    pass same-root-routing 'both project A buffers resolve to one workspace'
  else
    fail same-root-routing "unexpected state: $state"
  fi
else
  fail same-root-routing 'could not record project A workspace state'
fi

if invoke_mx lem-yath-test-lsp-open-project-b &&
   wait_event_count INITIALIZE "root_path=${LEM_YATH_LSP_TEST_PROJECT_B%/}" 1 &&
   wait_event_count DID_OPEN "root_path=${LEM_YATH_LSP_TEST_PROJECT_B%/}" 1; then
  assert_event_count different-root-server INITIALIZE \
    "root_path=${LEM_YATH_LSP_TEST_PROJECT_B%/}" 1
else
  fail different-root-server 'project B did not start its own server'
fi

if record_workspace_state; then
  state=$(grep '^STATE label=manual ' "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  if [[ "$state" == *'workspaces=2 same-a=yes isolated-b=yes '* ]]; then
    pass different-root-routing 'same-language projects resolve to isolated workspaces'
  else
    fail different-root-routing "unexpected state: $state"
  fi
else
  fail different-root-routing 'could not record two-project workspace state'
fi

invoke_mx lem-yath-test-lsp-activate-project-a >/dev/null ||
  fail workspace-symbol-origin 'could not activate project A'

# Capture the source window before the picker so abort can be checked against
# its exact point, viewport, and horizontal scroll rather than only its file.
source_count=$(report_count '^SYMBOL_SOURCE ')
lem_keys "$session" F11
wait_report_count '^SYMBOL_SOURCE ' "$((source_count + 1))" || true
symbol_origin=$(grep '^SYMBOL_SOURCE ' "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
symbol_origin_key=${symbol_origin%% prompt=*}

# Consult's defaults require three characters and debounce the resulting
# request.  Typing two characters and waiting longer than the debounce must
# not touch the server.
workspace_symbol_events_before=$(event_count WORKSPACE_SYMBOL '')
if invoke_mx lem-yath-workspace-symbol 'LSP Symbols:'; then
  tmux_cmd send-keys -t "$session" -l al
  sleep 0.45
  if [ "$(event_count WORKSPACE_SYMBOL '')" -eq \
       "$workspace_symbol_events_before" ]; then
    pass workspace-symbol-min-input \
      'two characters do not start an async workspace request'
  else
    fail workspace-symbol-min-input \
      'a workspace request escaped Consult minimum-input gating'
  fi

  tmux_cmd send-keys -t "$session" -l pha
  if wait_event_count WORKSPACE_SYMBOL 'query=alpha' 1 &&
     lem_wait_for "$session" 'AlphaSymbol' 10 >/dev/null &&
     lem_wait_for "$session" 'symbols.fixture' 10 >/dev/null; then
    assert_event_count workspace-symbol-debounce WORKSPACE_SYMBOL \
      'query=alpha' 1
    screen=$(lem_capture "$session")
    if grep -qi 'Function' <<<"$screen" &&
       grep -q 'Project A' <<<"$screen" &&
       grep -q 'symbols.fixture' <<<"$screen"; then
      pass workspace-symbol-annotations \
        'name, kind group, container, and source file are visible'
    else
      fail workspace-symbol-annotations \
        'workspace-symbol candidate is missing a Consult annotation'
    fi

    source_count=$(report_count '^SYMBOL_SOURCE ')
    lem_keys "$session" F11
    if wait_report_count '^SYMBOL_SOURCE ' "$((source_count + 1))"; then
      symbol_preview=$(grep '^SYMBOL_SOURCE ' \
        "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
      if [[ "$symbol_preview" == \
           *'/project-a/symbols.fixture line=3 column=4 '* &&
          "$symbol_preview" == *'prompt=yes preview=yes query="alpha"'* ]]; then
        pass workspace-symbol-preview \
          'focused result previews its exact LSP position'
      else
        fail workspace-symbol-preview \
          "unexpected preview state: $symbol_preview"
      fi
    else
      fail workspace-symbol-preview 'could not inspect the source window'
    fi

    lem_keys "$session" C-g
    sleep 0.35
    source_count=$(report_count '^SYMBOL_SOURCE ')
    lem_keys "$session" F11
    if wait_report_count '^SYMBOL_SOURCE ' "$((source_count + 1))"; then
      symbol_restored=$(grep '^SYMBOL_SOURCE ' \
        "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
      symbol_restored_key=${symbol_restored%% prompt=*}
      if [ "$symbol_restored_key" = "$symbol_origin_key" ] &&
         [[ "$symbol_restored" == *'prompt=no preview=no query=""'* ]]; then
        pass workspace-symbol-cancel \
          'C-g restores the exact source buffer, point, viewport, and scroll'
      else
        fail workspace-symbol-cancel \
          "abort did not restore origin: $symbol_restored"
      fi
    else
      fail workspace-symbol-cancel 'could not inspect the cancelled picker'
    fi
  else
    fail workspace-symbol-results \
      'the debounced response did not populate the incremental picker'
    lem_keys "$session" C-g
  fi
else
  fail workspace-symbol-prompt 'the single incremental prompt did not open'
fi

# A server-side error must leave the same prompt usable.  Replacing its input
# immediately issues a successful request without reopening the command.
if invoke_mx lem-yath-workspace-symbol 'LSP Symbols:'; then
  tmux_cmd send-keys -t "$session" -l explode
  if wait_event_count WORKSPACE_SYMBOL 'query=explode' 1 &&
     lem_wait_for "$session" 'LSP Symbols:' 10 >/dev/null; then
    pass workspace-symbol-error-recovery \
      'a failed request leaves the incremental prompt active'
  else
    fail workspace-symbol-error-recovery \
      'the server error closed or wedged the workspace-symbol prompt'
  fi

  prompt_backspace 7
  tmux_cmd send-keys -t "$session" -l alpha
  if wait_event_count WORKSPACE_SYMBOL 'query=alpha' 2 &&
     lem_wait_for "$session" 'AlphaSymbol' 10 >/dev/null; then
    lem_keys "$session" Enter
    sleep 0.45
    before=$(report_count '^LOCATION ')
    lem_keys "$session" F12
    if wait_report_count '^LOCATION ' "$((before + 1))"; then
      location=$(grep '^LOCATION ' "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
      if [[ "$location" == \
           *'/project-a/symbols.fixture line=3 column=4 pulse=yes pulse-line=3 pulse-buffer=yes' ]]; then
        pass workspace-symbol-jump \
          'one Return commits the exact LSP location and pulses its line'
      else
        fail workspace-symbol-jump "unexpected selection location: $location"
      fi
    else
      fail workspace-symbol-jump 'could not record the post-selection location'
    fi

    lem_keys "$session" C-o
    sleep 0.35
    before=$(report_count '^LOCATION ')
    lem_keys "$session" F12
    if wait_report_count '^LOCATION ' "$((before + 1))"; then
      location=$(grep '^LOCATION ' "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
      if [[ "$location" == *'/project-a/one.fixture '* ]]; then
        pass workspace-symbol-jumplist \
          'Vi C-o returns from the accepted Consult-style jump'
      else
        fail workspace-symbol-jumplist \
          "C-o did not return to the invoking buffer: $location"
      fi
    fi
  else
    fail workspace-symbol-error-recovery \
      'the same prompt did not recover with a successful query'
    lem_keys "$session" C-g
  fi
else
  fail workspace-symbol-error-recovery \
    'workspace-symbol prompt could not start for the error scenario'
fi

# The slow response is deliberately superseded.  The client must remove its
# callback, send $/cancelRequest, reject the stale generation, and retain the
# invoking project's workspace even though preview changes the source buffer.
invoke_mx lem-yath-test-lsp-activate-project-a >/dev/null || true
if invoke_mx lem-yath-workspace-symbol 'LSP Symbols:'; then
  tmux_cmd send-keys -t "$session" -l slowalpha
  if wait_event_count WORKSPACE_SYMBOL 'query=slowalpha' 1; then
    prompt_backspace 9
    tmux_cmd send-keys -t "$session" -l beta
    if wait_event_count CANCEL_REQUEST \
         "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" 1 &&
       wait_event_count WORKSPACE_SYMBOL 'query=beta' 1 &&
       lem_wait_for "$session" 'BetaSymbol' 10 >/dev/null; then
      screen=$(lem_capture "$session")
      if ! grep -q 'StaleSymbol' <<<"$screen" &&
         grep -E '^WORKSPACE_SYMBOL[[:space:]]' \
           "$LEM_YATH_LSP_TEST_EVENTS" |
           grep -F "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" |
           grep -Fq 'query=beta'; then
        pass workspace-symbol-stale-response \
          'superseded callback is cancelled and cannot replace newer results'
        pass workspace-symbol-stable-routing \
          'all incremental requests stay on the invoking project workspace'
      else
        fail workspace-symbol-stale-response \
          'a stale result appeared or the request changed projects'
      fi
    else
      fail workspace-symbol-stale-response \
        'cancellation or the replacement response was not observed'
    fi
  else
    fail workspace-symbol-stale-response 'the delayed request was not observed'
  fi
  lem_keys "$session" C-g
else
  fail workspace-symbol-stale-response \
    'workspace-symbol prompt could not start for the stale-response scenario'
fi

# Accepting a row must retain the search input in history, not replace it with
# the selected symbol label.  This mirrors Consult's :input history.
if invoke_mx lem-yath-workspace-symbol 'LSP Symbols:'; then
  lem_keys "$session" M-p
  if wait_event_count WORKSPACE_SYMBOL 'query=alpha' 3 &&
     lem_wait_for "$session" 'LSP Symbols: alpha' 10 >/dev/null; then
    pass workspace-symbol-history \
      'M-p restores and reissues the accepted search query'
  else
    fail workspace-symbol-history \
      'history stored a selected label or failed to refresh the query'
  fi
  lem_keys "$session" C-g
else
  fail workspace-symbol-history \
    'workspace-symbol prompt could not reopen for history validation'
fi

# With Consult's default narrow prefix unset, a case-sensitive kind key plus
# Space narrows before the ordinary query is entered.  The fixture returns a
# Function and Constant for the same query so both exclusion directions and
# empty-Backspace widening are visible in the real popup.
workspace_symbol_alpha_before=$(event_count WORKSPACE_SYMBOL 'query=alpha')
if invoke_mx lem-yath-workspace-symbol 'LSP Symbols:'; then
  tmux_cmd send-keys -t "$session" -l f
  lem_keys "$session" Space
  if lem_wait_for "$session" 'LSP Symbols: \[Function\]' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l alpha
    if wait_event_count WORKSPACE_SYMBOL 'query=alpha' \
         "$((workspace_symbol_alpha_before + 1))" &&
       lem_wait_for "$session" 'AlphaSymbol' 10 >/dev/null; then
      screen=$(lem_capture "$session")
      if ! grep -q 'AlphaConstant' <<<"$screen"; then
        pass workspace-symbol-narrow-function \
          'f Space shows only Function symbols under a visible indicator'
      else
        fail workspace-symbol-narrow-function \
          'Function narrowing retained a Constant result'
      fi
    else
      fail workspace-symbol-narrow-function \
        'the narrowed Function query did not produce its matching result'
    fi
  else
    fail workspace-symbol-narrow-function \
      'f Space did not install the Function prompt indicator'
  fi

  prompt_backspace 5
  sleep 0.35
  tmux_cmd send-keys -t "$session" -l C
  lem_keys "$session" Space
  if lem_wait_for "$session" 'LSP Symbols: \[Constant\]' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l alpha
    if wait_event_count WORKSPACE_SYMBOL 'query=alpha' \
         "$((workspace_symbol_alpha_before + 2))" &&
      lem_wait_for "$session" 'AlphaConstant' 10 >/dev/null; then
      screen=$(lem_capture "$session")
      if ! grep -qE 'AlphaSymbol[[:space:]]+\[Function\]' <<<"$screen"; then
        pass workspace-symbol-narrow-case \
          'uppercase C selects Constant independently of lowercase keys'
      else
        fail workspace-symbol-narrow-case \
          'Constant narrowing retained a Function result'
      fi
    else
      fail workspace-symbol-narrow-case \
        'the narrowed Constant query did not produce its matching result'
    fi
  else
    fail workspace-symbol-narrow-case \
      'uppercase C Space did not install the Constant prompt indicator'
  fi

  prompt_backspace 5
  sleep 0.35
  lem_keys "$session" BSpace
  sleep 0.35
  screen=$(lem_capture "$session")
  if grep -q 'LSP Symbols:' <<<"$screen" &&
     ! grep -q 'LSP Symbols: \[' <<<"$screen"; then
    tmux_cmd send-keys -t "$session" -l alpha
    if wait_event_count WORKSPACE_SYMBOL 'query=alpha' \
         "$((workspace_symbol_alpha_before + 3))" &&
       lem_wait_for "$session" 'AlphaSymbol' 10 >/dev/null &&
       lem_wait_for "$session" 'AlphaConstant' 10 >/dev/null; then
      pass workspace-symbol-widen \
        'Backspace on an empty narrow restores every symbol kind'
    else
      fail workspace-symbol-widen \
        'the widened query did not restore both fixture kinds'
    fi
  else
    fail workspace-symbol-widen \
      'empty Backspace did not remove the narrow prompt indicator'
  fi
  lem_keys "$session" C-g
else
  fail workspace-symbol-narrow-setup \
    'workspace-symbol prompt could not start for narrowing validation'
fi

# Consult-Eglot fans one query out to every symbol-capable server registered to
# the current project.  Start a second language server at project A's root;
# project B remains live and must never receive A's symbol query.
a_initializes_before_peer=$(event_count INITIALIZE \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
if invoke_mx lem-yath-test-lsp-open-symbol-peer &&
   wait_event_count INITIALIZE \
     "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_initializes_before_peer + 1))" &&
   wait_event_count DID_OPEN 'language_id=lem-yath-symbol-peer-fixture' 1; then
  pass workspace-symbol-peer-start \
    'a second language server is live in the invoking project'
else
  fail workspace-symbol-peer-start \
    'the same-project symbol server did not initialize'
fi

invoke_mx lem-yath-test-lsp-activate-project-a >/dev/null || true
alpha_before_multi=$(event_count WORKSPACE_SYMBOL 'query=alpha')
b_alpha_before_multi=$(grep -E '^WORKSPACE_SYMBOL[[:space:]]' \
  "$LEM_YATH_LSP_TEST_EVENTS" 2>/dev/null |
  grep -F "root_path=${LEM_YATH_LSP_TEST_PROJECT_B%/}" |
  grep -Fc 'query=alpha' || true)
if invoke_mx lem-yath-workspace-symbol 'LSP Symbols:'; then
  tmux_cmd send-keys -t "$session" -l alpha
  if wait_event_count WORKSPACE_SYMBOL 'query=alpha' \
       "$((alpha_before_multi + 2))" &&
     lem_wait_for "$session" 'AlphaSymbol' 10 >/dev/null; then
    early_screen=$(lem_capture "$session")
    if ! grep -q 'PeerAlphaSymbol' <<<"$early_screen"; then
      pass workspace-symbol-progressive \
        'the first server refreshes results without waiting for the slower peer'
    else
      fail workspace-symbol-progressive \
        'the delayed peer result appeared before the first progressive refresh'
    fi
    multi_report_before=$(report_count '^SYMBOL_SOURCE ')
    sleep 1
    lem_keys "$session" F11
    wait_report_count '^SYMBOL_SOURCE ' "$((multi_report_before + 1))" || true
    multi_symbol_state=$(grep '^SYMBOL_SOURCE ' \
      "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
    if lem_wait_for "$session" 'PeerAlphaSymbol' 10 >/dev/null &&
       lem_wait_for "$session" 'peer-symbols.fixture' 10 >/dev/null; then
      b_alpha_after_multi=$(grep -E '^WORKSPACE_SYMBOL[[:space:]]' \
        "$LEM_YATH_LSP_TEST_EVENTS" 2>/dev/null |
        grep -F "root_path=${LEM_YATH_LSP_TEST_PROJECT_B%/}" |
        grep -Fc 'query=alpha' || true)
      if [ "$b_alpha_after_multi" -eq "$b_alpha_before_multi" ]; then
        pass workspace-symbol-project-fanout \
          'same-project servers aggregate while another project is excluded'
      else
        fail workspace-symbol-project-fanout \
          'the invoking project query leaked to project B'
      fi
    else
      fail workspace-symbol-project-fanout \
        "the delayed peer was not visible; state: $multi_symbol_state"
    fi
  else
    fail workspace-symbol-progressive \
      'the primary server did not refresh the multi-server picker'
  fi
  lem_keys "$session" C-g
else
  fail workspace-symbol-project-fanout \
    'the multi-server workspace-symbol prompt did not open'
fi

# One server rejects `explode`, while the peer deliberately succeeds.  The
# healthy result must survive the failing response and the prompt must remain
# active, matching Consult-Eglot's per-server error isolation.
explode_before_multi=$(event_count WORKSPACE_SYMBOL 'query=explode')
if invoke_mx lem-yath-workspace-symbol 'LSP Symbols:'; then
  tmux_cmd send-keys -t "$session" -l explode
  if wait_event_count WORKSPACE_SYMBOL 'query=explode' \
       "$((explode_before_multi + 2))" &&
     lem_wait_for "$session" 'PeerExplodeSymbol' 10 >/dev/null &&
     lem_wait_for "$session" 'LSP Symbols:' 10 >/dev/null; then
    pass workspace-symbol-partial-error \
      'one failed server cannot erase a healthy peer response'
  else
    fail workspace-symbol-partial-error \
      'a server error erased the peer result or closed the prompt'
  fi
  lem_keys "$session" C-g
else
  fail workspace-symbol-partial-error \
    'the partial-error workspace-symbol prompt did not open'
fi

# Superseding a fan-out query invalidates and cancels both live callbacks.  A
# late response from either server must be unable to replace the beta results.
slow_before_multi=$(event_count WORKSPACE_SYMBOL 'query=slowalpha')
beta_before_multi=$(event_count WORKSPACE_SYMBOL 'query=beta')
cancel_before_multi=$(event_count CANCEL_REQUEST \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
if invoke_mx lem-yath-workspace-symbol 'LSP Symbols:'; then
  tmux_cmd send-keys -t "$session" -l slowalpha
  if wait_event_count WORKSPACE_SYMBOL 'query=slowalpha' \
       "$((slow_before_multi + 2))"; then
    prompt_backspace 9
    tmux_cmd send-keys -t "$session" -l beta
    if wait_event_count CANCEL_REQUEST \
         "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
         "$((cancel_before_multi + 2))" &&
       wait_event_count WORKSPACE_SYMBOL 'query=beta' \
         "$((beta_before_multi + 2))" 20 &&
       lem_wait_for "$session" 'BetaSymbol' 10 >/dev/null; then
      sleep 0.35
      screen=$(lem_capture "$session")
      if ! grep -q 'StaleSymbol' <<<"$screen"; then
        pass workspace-symbol-fanout-cancel \
          'replacement input cancels every server and rejects both stale callbacks'
      else
        fail workspace-symbol-fanout-cancel \
          'a cancelled multi-server response replaced the current results'
      fi
    else
      fail workspace-symbol-fanout-cancel \
        'both cancellations or both replacement responses were not observed'
    fi
  else
    fail workspace-symbol-fanout-cancel \
      'both slow multi-server requests were not observed'
  fi
  lem_keys "$session" C-g
else
  fail workspace-symbol-fanout-cancel \
    'the multi-server cancellation prompt did not open'
fi

# The deterministic fixture handles requests serially, so its cancelled sleep
# can delay later messages even though the client removed both callbacks.
# Recycle only that peer before independently testing peer navigation.
peer_reset_initialize_before=$(event_count INITIALIZE \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
invoke_mx lem-yath-test-lsp-close-symbol-peer >/dev/null || true
if invoke_mx lem-yath-test-lsp-open-symbol-peer &&
   wait_event_count INITIALIZE \
     "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((peer_reset_initialize_before + 1))" 30; then
  invoke_mx lem-yath-test-lsp-activate-project-a >/dev/null || true
else
  fail workspace-symbol-peer-reset \
    'the peer fixture could not be recycled after cancellation'
fi

# A query matching only the peer result proves preview and commit use the
# candidate's source workspace rather than the invoking language server.
peer_before_multi=$(event_count WORKSPACE_SYMBOL 'query=peer')
if invoke_mx lem-yath-workspace-symbol 'LSP Symbols:'; then
  tmux_cmd send-keys -t "$session" -l peer
  if wait_event_count WORKSPACE_SYMBOL 'query=peer' \
       "$((peer_before_multi + 2))"; then
    peer_report_before=$(report_count '^SYMBOL_SOURCE ')
    sleep 1
    lem_keys "$session" F11
    wait_report_count '^SYMBOL_SOURCE ' "$((peer_report_before + 1))" || true
    peer_symbol_state=$(grep '^SYMBOL_SOURCE ' \
      "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  else
    peer_symbol_state='requests were not observed'
  fi
  if lem_wait_for "$session" 'PeerAlphaSymbol' 10 >/dev/null; then
    source_count=$(report_count '^SYMBOL_SOURCE ')
    lem_keys "$session" F11
    if wait_report_count '^SYMBOL_SOURCE ' "$((source_count + 1))"; then
      peer_preview=$(grep '^SYMBOL_SOURCE ' \
        "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
      if [[ "$peer_preview" == \
           *'/project-a/peer-symbols.fixture line=3 column=4 '* ]]; then
        pass workspace-symbol-peer-preview \
          'a peer-only candidate previews through its source workspace'
      else
        fail workspace-symbol-peer-preview \
          "unexpected peer preview: $peer_preview"
      fi
    else
      fail workspace-symbol-peer-preview \
        'the peer candidate preview could not be inspected'
    fi
    lem_keys "$session" Enter
    sleep 0.45
    before=$(report_count '^LOCATION ')
    lem_keys "$session" F12
    if wait_report_count '^LOCATION ' "$((before + 1))"; then
      location=$(grep '^LOCATION ' "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
      if [[ "$location" == \
           *'/project-a/peer-symbols.fixture line=3 column=4 '* ]]; then
        pass workspace-symbol-peer-jump \
          'Return commits a symbol supplied by the secondary server'
      else
        fail workspace-symbol-peer-jump \
          "unexpected peer selection location: $location"
      fi
    else
      fail workspace-symbol-peer-jump \
        'the committed peer location could not be inspected'
    fi
  else
    fail workspace-symbol-peer-preview \
      "the peer-only query did not produce its candidate; state: $peer_symbol_state"
    lem_keys "$session" C-g
  fi
else
  fail workspace-symbol-peer-jump \
    'the peer navigation prompt did not open'
fi

invoke_mx lem-yath-test-lsp-close-symbol-peer >/dev/null ||
  fail workspace-symbol-peer-stop 'the peer workspace could not be disposed'
invoke_mx lem-yath-test-lsp-activate-project-a >/dev/null || true

# Restart must replace project A once, reopen both of its live buffers, and
# leave project B's server and open document untouched.
invoke_mx lem-yath-test-lsp-activate-project-a >/dev/null || true
a_pid_before_restart=$(latest_event_pid INITIALIZE \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
a_initialize_before_restart=$(event_count INITIALIZE \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
a_open_before_restart=$(event_count DID_OPEN \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
a_shutdown_before_restart=$(event_count SHUTDOWN \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
a_exit_before_restart=$(event_count EXIT \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
if invoke_mx lsp-restart-server &&
   wait_event_count INITIALIZE "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_initialize_before_restart + 1))" 30 &&
   wait_event_count DID_OPEN "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_open_before_restart + 2))" 30 &&
   wait_event_count SHUTDOWN "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_shutdown_before_restart + 1))" &&
   wait_event_count EXIT "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_exit_before_restart + 1))"; then
  assert_event_count restart-one-replacement INITIALIZE \
    "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
    "$((a_initialize_before_restart + 1))"
  assert_event_count restart-reopens-project DID_OPEN \
    "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
    "$((a_open_before_restart + 2))"
  assert_event_count restart-isolates-other-root INITIALIZE \
    "root_path=${LEM_YATH_LSP_TEST_PROJECT_B%/}" 1
  assert_event_count restart-preserves-other-open DID_OPEN \
    "root_path=${LEM_YATH_LSP_TEST_PROJECT_B%/}" 1
  pass restart-graceful-shutdown 'the replaced server received shutdown and exit'
  if [ -n "$a_pid_before_restart" ] && wait_pid_dead "$a_pid_before_restart"; then
    pass restart-disposes-old 'the replaced project A server process exited'
  else
    fail restart-disposes-old 'the replaced project A server process is still alive'
  fi
else
  fail restart-project 'project A did not restart and reopen both buffers'
fi

if record_workspace_state; then
  state=$(grep '^STATE label=manual ' "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  if [[ "$state" == *'workspaces=2 same-a=yes isolated-b=yes '* ]]; then
    pass restart-registry 'restart replaced, rather than duplicated, the workspace'
  else
    fail restart-registry "unexpected post-restart state: $state"
  fi
fi

# Exact buffer binding restoration matters when a language handler is inherited
# from the editor-wide default.  Exercise unbound -> LSP-local -> unbound, then
# prove a later global change is visible through that same buffer.
handler_report_before=$(report_count '^HANDLER-RESTORE ')
handler_open_before=$(event_count DID_OPEN \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
handler_close_before=$(event_count DID_CLOSE \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
if invoke_mx lem-yath-test-lsp-handler-binding-restoration &&
   wait_report_count '^HANDLER-RESTORE ' "$((handler_report_before + 1))" &&
   wait_event_count DID_OPEN "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((handler_open_before + 2))" &&
   wait_event_count DID_CLOSE "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((handler_close_before + 2))"; then
  handler_state=$(grep '^HANDLER-RESTORE ' \
    "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  if [ "$handler_state" = \
       'HANDLER-RESTORE before-unbound=yes inherited-a=yes installed=yes after-unbound=yes restored-a=yes follows-b=yes active=yes' ]; then
    pass handler-binding-restoration \
      'disable restored an unbound local handler that follows later global changes'
  else
    fail handler-binding-restoration "unexpected handler state: $handler_state"
  fi
else
  fail handler-binding-restoration \
    'the inherited handler binding did not survive the enable/disable cycle'
fi

# Disabling LSP must remove explicit ownership and restore the major mode's
# previous completion/xref handlers.  Re-enabling should reuse the same cached
# project workspace and reopen exactly one document.
a_disable_close_before=$(event_count DID_CLOSE \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
disable_report_before=$(report_count '^DISABLE ')
if invoke_mx lem-yath-test-lsp-disable-project-a-two &&
   wait_event_count DID_CLOSE "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_disable_close_before + 1))" &&
   wait_report_count '^DISABLE ' "$((disable_report_before + 1))"; then
  disable_state=$(grep '^DISABLE ' "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  if [[ "$disable_state" == \
        'DISABLE owned=no completion=no definitions=no references=no revert=no' ]]; then
    pass disable-ownership \
      'disable sent didClose, cleared ownership, and restored prior handlers'
  else
    fail disable-ownership "unexpected disable state: $disable_state"
  fi
else
  fail disable-ownership 'disabling one project buffer did not detach it cleanly'
fi

a_reenable_open_before=$(event_count DID_OPEN \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
a_reenable_initialize_before=$(event_count INITIALIZE \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
reenable_report_before=$(report_count '^REENABLE ')
if invoke_mx lem-yath-test-lsp-enable-project-a-two &&
   wait_event_count DID_OPEN "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_reenable_open_before + 1))" &&
   wait_report_count '^REENABLE owned=yes$' "$((reenable_report_before + 1))"; then
  assert_event_count reenable-reuses-project INITIALIZE \
    "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
    "$a_reenable_initialize_before"
else
  fail reenable-ownership 're-enabling did not reuse and reopen the project workspace'
fi

# Saving an attached A buffer under project B must use the URI that was
# actually opened for didClose, reuse B's existing server, then didOpen and
# didSave the new encoded URI.  Detach also clears A's diagnostic state.
diagnostic_report_before=$(report_count '^DIAGNOSTIC phase=a ')
if invoke_mx lem-yath-test-lsp-record-project-a-diagnostics &&
   wait_report_count '^DIAGNOSTIC phase=a ' "$((diagnostic_report_before + 1))"; then
  diagnostic_state=$(grep '^DIAGNOSTIC phase=a ' \
    "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  if [ "$diagnostic_state" = \
       'DIAGNOSTIC phase=a count=1 timer=yes current=yes init-timer=no spinner=no' ]; then
    pass diagnostics-before-save 'project A owns a live diagnostic before migration'
  else
    fail diagnostics-before-save "unexpected diagnostic state: $diagnostic_state"
  fi
fi

a_original_uri="file://${LEM_YATH_LSP_TEST_PROJECT_A%/}/one.fixture"
b_migrated_uri="file://${LEM_YATH_LSP_TEST_PROJECT_B%/}/migrated%2Braw.fixture"
a_save_close_before=$(event_count DID_CLOSE "uri=$a_original_uri")
b_save_open_before=$(event_count DID_OPEN "uri=$b_migrated_uri")
b_save_before=$(event_count DID_SAVE "uri=$b_migrated_uri")
a_init_before_save=$(event_count INITIALIZE \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
b_init_before_save=$(event_count INITIALIZE \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_B%/}")
save_report_before=$(report_count '^SAVE-AS ')
if invoke_mx lem-yath-test-lsp-save-a-to-b &&
   confirm_yes_prompt 'migrated\+raw\.fixture exists; overwrite it' &&
   wait_event_count DID_CLOSE "uri=$a_original_uri" \
     "$((a_save_close_before + 1))" &&
   wait_event_count DID_OPEN "uri=$b_migrated_uri" \
     "$((b_save_open_before + 1))" &&
   wait_event_count DID_SAVE "uri=$b_migrated_uri" \
     "$((b_save_before + 1))" &&
   wait_report_count '^SAVE-AS ' "$((save_report_before + 1))"; then
  save_state=$(grep '^SAVE-AS ' "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  if [[ "$save_state" == *'/project-b/migrated+raw.fixture '* &&
        "$save_state" == *"opened=$b_migrated_uri "* &&
        "$save_state" == *'migrated=yes stale-old=no current-new=yes '* &&
        "$save_state" == *'diagnostics-clean=yes timer-clean=yes' ]]; then
    pass save-as-migration \
      'save-as closed the old URI, reused B, opened/saved new URI, and cleaned diagnostics'
  else
    fail save-as-migration "unexpected save-as state: $save_state"
  fi
  assert_event_count save-as-no-new-a-server INITIALIZE \
    "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" "$a_init_before_save"
  assert_event_count save-as-no-new-b-server INITIALIZE \
    "root_path=${LEM_YATH_LSP_TEST_PROJECT_B%/}" "$b_init_before_save"
else
  fail save-as-migration 'save-as did not produce the expected ownership notifications'
fi

# A real edit after save-as must notify only the newly owning B workspace and
# must use the encoded URI that was opened there.  No change may leak to A.
a_change_before=$(event_count DID_CHANGE "uri=$a_original_uri")
b_change_before=$(event_count DID_CHANGE "uri=$b_migrated_uri")
migrated_edit_report_before=$(report_count '^EDIT-MIGRATED ')
if invoke_mx lem-yath-test-lsp-edit-migrated &&
   wait_event_count DID_CHANGE "uri=$b_migrated_uri" \
     "$((b_change_before + 1))" &&
   wait_report_count '^EDIT-MIGRATED ' \
     "$((migrated_edit_report_before + 1))"; then
  migrated_edit_state=$(grep '^EDIT-MIGRATED ' \
    "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  if [ "$migrated_edit_state" = \
       "EDIT-MIGRATED opened=$b_migrated_uri current=yes changed=yes" ]; then
    pass post-save-change-routing \
      'a real edit sent one didChange through the new B workspace and URI'
  else
    fail post-save-change-routing \
      "unexpected migrated edit state: $migrated_edit_state"
  fi
  assert_event_count post-save-one-new-change DID_CHANGE \
    "uri=$b_migrated_uri" "$((b_change_before + 1))"
  assert_event_count post-save-no-old-change DID_CHANGE \
    "uri=$a_original_uri" "$a_change_before"
else
  fail post-save-change-routing \
    'the migrated edit did not produce its current-workspace notification'
fi

# B publishes a fresh diagnostic after didOpen.  Replaying a diagnostic with
# the old A workspace must be ignored by the ownership freshness guard.
stale_report_before=$(report_count '^STALE-DIAGNOSTIC ')
if wait_event_count PUBLISH_DIAGNOSTICS "uri=$b_migrated_uri" 1 &&
   invoke_mx lem-yath-test-lsp-stale-diagnostic-contract &&
   wait_report_count '^STALE-DIAGNOSTIC ' "$((stale_report_before + 1))"; then
  stale_state=$(grep '^STALE-DIAGNOSTIC ' \
    "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  if [ "$stale_state" = \
       'STALE-DIAGNOSTIC unchanged=yes old-current=no new-current=yes count=1 timer=yes' ]; then
    pass stale-diagnostic-ownership \
      'stale A response could not mutate the B-owned diagnostic state'
  else
    fail stale-diagnostic-ownership "unexpected stale-response state: $stale_state"
  fi
else
  fail stale-diagnostic-ownership 'fresh B diagnostic or stale probe did not complete'
fi

# A UI command that changes the migrated buffer's major mode is followed by
# lsp-mode's execute :after guard.  Record cleanup in a separate command so the
# after method has already run.
b_mode_close_before=$(event_count DID_CLOSE "uri=$b_migrated_uri")
mode_request_before=$(report_count '^MODE-CHANGE phase=requested$')
mode_done_before=$(report_count '^MODE-CHANGE phase=done ')
if invoke_mx lem-yath-test-lsp-change-migrated-major-mode &&
   wait_report_count '^MODE-CHANGE phase=requested$' \
     "$((mode_request_before + 1))" &&
   wait_event_count DID_CLOSE "uri=$b_migrated_uri" \
     "$((b_mode_close_before + 1))" &&
   invoke_mx lem-yath-test-lsp-record-major-mode-cleanup &&
   wait_report_count '^MODE-CHANGE phase=done ' "$((mode_done_before + 1))"; then
  mode_state=$(grep '^MODE-CHANGE phase=done ' \
    "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  if [ "$mode_state" = \
       'MODE-CHANGE phase=done owned=no lsp=no completion=no definitions=no references=no revert=no opened=no diagnostics-clean=yes timer-clean=yes stale=no' ]; then
    pass major-mode-detach \
      'major-mode change detached B, restored handlers, and cleared diagnostics'
  else
    fail major-mode-detach "unexpected major-mode state: $mode_state"
  fi
else
  fail major-mode-detach 'major-mode change did not close the migrated document'
fi

# Initialization timeout is globally shortened only for this fixture because
# transport connection and timer creation happen asynchronously.
timeout_report_before=$(report_count '^TIMEOUT phase=done ')
if invoke_mx lem-yath-test-lsp-start-timeout &&
   wait_event_count INITIALIZE \
     "root_path=${LEM_YATH_LSP_TEST_TIMEOUT_ROOT%/}" 1 10; then
  timeout_pid=$(latest_event_pid INITIALIZE \
    "root_path=${LEM_YATH_LSP_TEST_TIMEOUT_ROOT%/}")
  if lem_wait_for "$session" 'Language server initialization timed out' 10 >/dev/null &&
     invoke_mx lem-yath-test-lsp-record-timeout &&
     wait_report_count '^TIMEOUT phase=done ' "$((timeout_report_before + 1))" &&
     [ -n "$timeout_pid" ] && wait_pid_dead "$timeout_pid"; then
    timeout_state=$(grep '^TIMEOUT phase=done ' \
      "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
    if [ "$timeout_state" = \
         'TIMEOUT phase=done state=DISPOSED timer=no owned=no lsp=no spinner=no handlers=no global=30 workspaces=2' ]; then
      pass initialize-timeout \
        'silent initialize timed out, cleared UI/timer/handlers, and killed its process'
    else
      fail initialize-timeout "unexpected timeout state: $timeout_state"
    fi
    assert_event_count timeout-never-opened DID_OPEN \
      "root_path=${LEM_YATH_LSP_TEST_TIMEOUT_ROOT%/}" 0
  else
    fail initialize-timeout 'timeout cleanup or process termination did not complete'
  fi
else
  fail initialize-timeout 'timeout fixture did not send initialize'
fi

# Removing the only consumer while initialize is pending should cancel the
# startup immediately rather than leave a 30-second timer or orphan process.
pending_report_before=$(report_count '^PENDING phase=done ')
if invoke_mx lem-yath-test-lsp-start-pending &&
   wait_event_count INITIALIZE \
     "root_path=${LEM_YATH_LSP_TEST_PENDING_ROOT%/}" 1 10; then
  pending_pid=$(latest_event_pid INITIALIZE \
    "root_path=${LEM_YATH_LSP_TEST_PENDING_ROOT%/}")
  pending_change_before=$(event_count DID_CHANGE \
    "root_path=${LEM_YATH_LSP_TEST_PENDING_ROOT%/}")
  pending_edit_report_before=$(report_count '^PENDING phase=edited ')
  if invoke_mx lem-yath-test-lsp-edit-pending &&
     wait_report_count '^PENDING phase=edited ' \
       "$((pending_edit_report_before + 1))"; then
    pending_edit_state=$(grep '^PENDING phase=edited ' \
      "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
    pending_change_after=$(event_count DID_CHANGE \
      "root_path=${LEM_YATH_LSP_TEST_PENDING_ROOT%/}")
    if [ "$pending_edit_state" = \
         'PENDING phase=edited state=STARTING owned=yes changed=yes' ] &&
       [ "$pending_change_after" -eq "$pending_change_before" ]; then
      pass pending-edit-guard \
        'editing during initialization stayed local and did not abort the command'
    else
      fail pending-edit-guard \
        "unexpected pending edit state or didChange count: $pending_edit_state count=$pending_change_after"
    fi
  else
    fail pending-edit-guard 'editing during initialization did not complete'
  fi
  if invoke_mx lem-yath-test-lsp-cancel-pending &&
     wait_report_count '^PENDING phase=done ' "$((pending_report_before + 1))" &&
     [ -n "$pending_pid" ] && wait_pid_dead "$pending_pid"; then
    pending_state=$(grep '^PENDING phase=done ' \
      "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
    if [ "$pending_state" = \
         'PENDING phase=done state=DISPOSED timer=no spinner=no owned=no lsp=no workspaces=2' ]; then
      pass pending-zero-consumer \
        'last pending consumer canceled timer, spinner, registry entry, and process'
    else
      fail pending-zero-consumer "unexpected pending state: $pending_state"
    fi
    assert_event_count pending-never-opened DID_OPEN \
      "root_path=${LEM_YATH_LSP_TEST_PENDING_ROOT%/}" 0
  else
    fail pending-zero-consumer 'pending cancellation did not terminate its process'
  fi
else
  fail pending-zero-consumer 'pending fixture did not send initialize'
fi

# A server that sleeps five seconds before answering shutdown must not block
# Lem for that long.  The production one-second shutdown timeout bounds the
# command and unconditional process disposal finishes cleanup.
slow_report_before=$(report_count '^SLOW phase=done ')
if invoke_mx lem-yath-test-lsp-start-slow-shutdown &&
   wait_event_count INITIALIZE \
     "root_path=${LEM_YATH_LSP_TEST_SLOW_ROOT%/}" 1 10 &&
   wait_event_count DID_OPEN \
     "root_path=${LEM_YATH_LSP_TEST_SLOW_ROOT%/}" 1 10; then
  slow_pid=$(latest_event_pid INITIALIZE \
    "root_path=${LEM_YATH_LSP_TEST_SLOW_ROOT%/}")
  slow_started_ms=$(date +%s%3N)
  invoke_mx lsp-shutdown-server >/dev/null || true
  if lem_wait_for "$session" 'LSP workspace stopped' 6 >/dev/null &&
     wait_event_count SHUTDOWN \
       "root_path=${LEM_YATH_LSP_TEST_SLOW_ROOT%/}" 1 6 &&
     [ -n "$slow_pid" ] && wait_pid_dead "$slow_pid" 6; then
    slow_elapsed_ms=$(( $(date +%s%3N) - slow_started_ms ))
    invoke_mx lem-yath-test-lsp-record-slow-shutdown >/dev/null || true
    if (( slow_elapsed_ms < 4000 )) &&
       wait_report_count '^SLOW phase=done owned=no lsp=no handlers=no workspaces=2$' \
         "$((slow_report_before + 1))"; then
      pass bounded-shutdown \
        "five-second server delay was bounded to ${slow_elapsed_ms}ms and the PID died"
    else
      fail bounded-shutdown \
        "shutdown took ${slow_elapsed_ms}ms or left editor lifecycle state behind"
    fi
  else
    fail bounded-shutdown 'slow shutdown did not return or terminate its process'
  fi
else
  fail bounded-shutdown 'slow-shutdown fixture did not initialize'
fi

# Closing the last project A buffer sends didClose but intentionally retains
# its now-idle workspace, matching Eglot and Lem's existing lifetime policy.
a_close_before=$(event_count DID_CLOSE "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
idle_before=$(report_count '^STATE label=idle-a ')
if invoke_mx lem-yath-test-lsp-close-project-a &&
   wait_event_count DID_CLOSE "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_close_before + 1))" &&
   wait_report_count '^STATE label=idle-a ' "$((idle_before + 1))"; then
  idle_state=$(grep '^STATE label=idle-a ' "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  if [[ "$idle_state" == *'workspaces=2 '* && "$idle_state" == *'a-live=0' ]]; then
    pass idle-workspace-policy 'didClose ran and the last close retained an idle workspace'
  else
    fail idle-workspace-policy "unexpected idle state: $idle_state"
  fi
else
  fail idle-workspace-policy 'closing the remaining project A document did not send didClose'
fi

# Resolve and stop that idle workspace from an eligible same-project buffer
# that has no explicit workspace pointer, then enable it again from scratch.
idle_anchor_report_before=$(report_count '^IDLE-A phase=ready ')
a_anchor_open_before=$(event_count DID_OPEN \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
a_anchor_close_before=$(event_count DID_CLOSE \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
if invoke_mx lem-yath-test-lsp-prepare-idle-a-anchor &&
   wait_report_count '^IDLE-A phase=ready ' "$((idle_anchor_report_before + 1))" &&
   wait_event_count DID_OPEN "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_anchor_open_before + 1))" &&
   wait_event_count DID_CLOSE "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_anchor_close_before + 1))"; then
  idle_anchor_state=$(grep '^IDLE-A phase=ready ' \
    "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  if [ "$idle_anchor_state" = \
       'IDLE-A phase=ready owned=no lsp=no eligible=yes workspaces=2' ]; then
    pass idle-project-anchor 'an unowned eligible buffer resolves the idle project'
  else
    fail idle-project-anchor "unexpected idle anchor state: $idle_anchor_state"
  fi
else
  fail idle-project-anchor 'could not prepare the idle project anchor'
fi

a_idle_pid=$(latest_event_pid INITIALIZE \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
a_idle_shutdown_before=$(event_count SHUTDOWN \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
a_idle_exit_before=$(event_count EXIT \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
idle_stopped_report_before=$(report_count '^IDLE-A phase=stopped ')
if invoke_mx lsp-shutdown-server &&
   lem_wait_for "$session" 'LSP workspace stopped' 6 >/dev/null &&
   wait_event_count SHUTDOWN "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_idle_shutdown_before + 1))" &&
   wait_event_count EXIT "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_idle_exit_before + 1))" &&
   [ -n "$a_idle_pid" ] && wait_pid_dead "$a_idle_pid" &&
   invoke_mx lem-yath-test-lsp-record-idle-a-shutdown &&
   wait_report_count '^IDLE-A phase=stopped owned=no lsp=no workspaces=1$' \
     "$((idle_stopped_report_before + 1))"; then
  pass idle-project-shutdown \
    'explicit stop found the idle project, shut it down, and removed the registry entry'
else
  fail idle-project-shutdown 'explicit idle-project shutdown did not complete cleanly'
fi

a_reenable_init_before=$(event_count INITIALIZE \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
a_reenable_open_before=$(event_count DID_OPEN \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
idle_running_report_before=$(report_count '^IDLE-A phase=running ')
if invoke_mx lem-yath-test-lsp-reenable-idle-a &&
   wait_event_count INITIALIZE "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_reenable_init_before + 1))" 15 &&
   wait_event_count DID_OPEN "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_reenable_open_before + 1))" 15 &&
   wait_report_count '^IDLE-A phase=running ' "$((idle_running_report_before + 1))"; then
  idle_running_state=$(grep '^IDLE-A phase=running ' \
    "$LEM_YATH_LSP_TEST_REPORT" | tail -1)
  if [[ "$idle_running_state" == \
        'IDLE-A phase=running owned=yes state=READY opened='* &&
        "$idle_running_state" == *'init-timer=no workspaces=2' ]]; then
    pass idle-project-reenable \
      're-enable launched one clean replacement and reopened the anchor'
  else
    fail idle-project-reenable "unexpected re-enable state: $idle_running_state"
  fi
else
  fail idle-project-reenable 'idle project did not re-enable cleanly'
fi

# A normal editor exit runs dispose-all-workspaces.  Each initialized server
# should receive the protocol shutdown/exit sequence and its process must die;
# an EOF event is deliberately not required after the explicit exit message.
a_pid_before_exit=$(latest_event_pid INITIALIZE \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
b_pid_before_exit=$(latest_event_pid INITIALIZE \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_B%/}")
a_shutdown_before_exit=$(event_count SHUTDOWN \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
b_shutdown_before_exit=$(event_count SHUTDOWN \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_B%/}")
a_exit_before_exit=$(event_count EXIT \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}")
b_exit_before_exit=$(event_count EXIT \
  "root_path=${LEM_YATH_LSP_TEST_PROJECT_B%/}")
if invoke_mx exit-lem && wait_session_dead 30 &&
   wait_event_count SHUTDOWN "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_shutdown_before_exit + 1))" &&
   wait_event_count SHUTDOWN "root_path=${LEM_YATH_LSP_TEST_PROJECT_B%/}" \
     "$((b_shutdown_before_exit + 1))" &&
   wait_event_count EXIT "root_path=${LEM_YATH_LSP_TEST_PROJECT_A%/}" \
     "$((a_exit_before_exit + 1))" &&
   wait_event_count EXIT "root_path=${LEM_YATH_LSP_TEST_PROJECT_B%/}" \
     "$((b_exit_before_exit + 1))" &&
   [ -n "$a_pid_before_exit" ] && [ -n "$b_pid_before_exit" ] &&
   wait_pid_dead "$a_pid_before_exit" && wait_pid_dead "$b_pid_before_exit"; then
  pass exit-cleanup 'normal exit gracefully disposed both active project clients'
else
  fail exit-cleanup 'one or more active clients survived normal editor exit'
fi

if ((failed)); then
  exit 1
fi

printf 'All project-scoped LSP checks passed.\n'
