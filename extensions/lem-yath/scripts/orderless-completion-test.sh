#!/usr/bin/env bash
# Real-ncurses regressions for Orderless matching in ordinary completion.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-orderless-completion-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-orderless-completion.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export LEM_YATH_ORDERLESS_COMPLETION_REPORT="$root/report"
export LEM_YATH_ORDERLESS_FILE_DIR="$root/files/"
mkdir -p "$HOME" "$WORKDIR/roam" "$LEM_YATH_ORDERLESS_FILE_DIR"
touch "$LEM_YATH_ORDERLESS_FILE_DIR/alpha-file.txt"
touch "$LEM_YATH_ORDERLESS_FILE_DIR/alpine-file.txt"
mkdir -p "$LEM_YATH_ORDERLESS_FILE_DIR/abc"
touch "$LEM_YATH_ORDERLESS_FILE_DIR/abc/native-file.txt"
touch "$LEM_YATH_ORDERLESS_FILE_DIR/abc/native-other.txt"
source "$here/scripts/tui-driver.sh"

session="lem-yath-orderless-completion-$id"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %-32s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-32s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
}

report_count() {
  local pattern=$1
  grep -cE "$pattern" "$LEM_YATH_ORDERLESS_COMPLETION_REPORT" 2>/dev/null || true
}

wait_report() {
  local pattern=$1 timeout=${2:-10} i=0
  while ((i < timeout * 4)); do
    if [ -f "$LEM_YATH_ORDERLESS_COMPLETION_REPORT" ] &&
       grep -qE "$pattern" "$LEM_YATH_ORDERLESS_COMPLETION_REPORT"; then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

wait_report_count() {
  local pattern=$1 expected=$2 timeout=${3:-10} i=0
  while ((i < timeout * 4)); do
    if (( $(report_count "$pattern") >= expected )); then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

run_mx() {
  local command=$1
  # Corfu Escape is deliberately staged (selection, input, then popup), so a
  # fixed number of Escapes cannot guarantee that Vi has left Insert state.
  # C-g closes completion in one stage; the following Escape is then Vi's.
  lem_keys "$session" C-g
  sleep 0.15
  lem_keys "$session" Escape
  sleep 0.15
  lem_wait_for "$session" 'NORMAL' 5 >/dev/null || return 1
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.5
  lem_keys "$session" Enter
  sleep 0.4
}

invoke_prompt() {
  lem_keys "$session" Escape
  sleep 0.15
  lem_keys "$session" Escape
  sleep 0.15
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l lem-yath-test-orderless-prompt
  sleep 0.5
  lem_keys "$session" Enter
  lem_wait_for "$session" 'Orderless prompt:' 10 >/dev/null
}

enter_insert() {
  lem_keys "$session" i
  lem_wait_for "$session" 'INSERT' 5 >/dev/null
}

latest_state() {
  grep '^STATE ' "$LEM_YATH_ORDERLESS_COMPLETION_REPORT" 2>/dev/null | tail -n 1
}

request_has_space() {
  grep -Eq '^REQUEST (sync|async|manual) input="[^"]* [^"]*"' \
    "$LEM_YATH_ORDERLESS_COMPLETION_REPORT" 2>/dev/null
}

fixture="$(lem-yath_lisp_string "$here/scripts/orderless-completion-fixture.lisp")"
scratch="$root/orderless.txt"
: >"$scratch"
lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$scratch"
if ! lem_wait_for "$session" 'NORMAL' 40 >/dev/null; then
  fail boot "Lem did not reach the fixture buffer"
else
  pass boot "fixture loaded in the real ncurses editor"
fi

if run_mx lem-yath-test-orderless-static-checks &&
   wait_report '^SUMMARY STATIC PASS failures=0$' 15; then
  pass matcher-oracle "smart case, overlap, regexp, escaping, and affixes passed"
else
  fail matcher-oracle "one or more pure matcher vectors failed"
fi

# The pinned % dispatcher is directional: plain ASCII input can match
# diacritic-bearing filterText, while acceptance retains item insertion identity.
if run_mx lem-yath-test-orderless-character-fold-setup &&
   wait_report '^SETUP fold$' 10 && enter_insert; then
  tmux_cmd send-keys -t "$session" -l caf
  if lem_wait_for "$session" 'CAFE-DECOY' 10 >/dev/null; then
    lem_keys "$session" M-Space
    tmux_cmd send-keys -t "$session" -l %resume
    if lem_wait_for "$session" 'CAFÉ-TARGET' 10 >/dev/null; then
      sleep 0.4
      state_before=$(report_count '^STATE ')
      lem_keys "$session" F5
      wait_report_count '^STATE ' $((state_before + 1)) 5 || true
      fold_state=$(latest_state)
      if [[ "$fold_state" == *'items=1 popup=T input=caf %resume buffer=caf %resume requests=1 focus=CAFÉ-TARGET'* ]]; then
        lem_keys "$session" Enter
        if wait_report '^ACCEPT label=CAFÉ-TARGET buffer=folded_identity$' 5; then
          pass character-fold-popup "% matched diacritics through filterText and preserved insertion identity"
        else
          fail character-fold-popup "folded candidate acceptance lost insertion identity"
        fi
      else
        fail character-fold-popup "local folding did not isolate the target from the plain decoy"
      fi
    else
      fail character-fold-popup "% did not match the diacritic-bearing candidate"
    fi
  else
    fail character-fold-popup "the initial character-fold provider did not open"
  fi
else
  fail character-fold-setup "could not prepare the character-fold provider"
fi

# The provider returns 120 candidates; the sole second/third-component match
# is raw item 119 and has distinct label, filterText, and insertText values.
if run_mx lem-yath-test-orderless-sync-setup &&
   wait_report '^SETUP sync$' 10 && enter_insert; then
  tmux_cmd send-keys -t "$session" -l alp
  if lem_wait_for "$session" 'CANDIDATE-[0-9][0-9][0-9]' 10 >/dev/null &&
     wait_report '^REQUEST sync input="alp" count=1$' 10; then
    screen=$(lem_capture "$session")
    state_before=$(report_count '^STATE ')
    lem_keys "$session" F5
    wait_report_count '^STATE ' $((state_before + 1)) 5 || true
    state=$(latest_state)
    if [[ "$state" == *'local=NIL filter=T separator=T raw=120 items=100 popup=T input=alp buffer=alp requests=1'* ]] &&
       ! grep -q 'TARGET-BEYOND-100' <<<"$screen"; then
      pass raw-before-cap "all 120 raw items were retained while only 100 were presented"
    else
      fail raw-before-cap "raw/presented counts or initial target position were wrong"
    fi

    lem_keys "$session" M-Space
    tmux_cmd send-keys -t "$session" -l spec
    if lem_wait_for "$session" 'TARGET-BEYOND-100' 10 >/dev/null; then
      pass m-space-local-filter "M-Space exposed a match beyond the initial 100-item cap"
    else
      fail m-space-local-filter "the frozen raw batch did not expose item 119"
    fi

    lem_keys "$session" Space
    tmux_cmd send-keys -t "$session" -l target
    if lem_wait_for "$session" 'TARGET-BEYOND-100' 10 >/dev/null; then
      state_before=$(report_count '^STATE ')
      lem_keys "$session" F5
      wait_report_count '^STATE ' $((state_before + 1)) 5 || true
      state=$(latest_state)
      if [[ "$state" == *'local=T filter=T separator=T raw=120 items=1 popup=T input=alp spec target buffer=alp spec target requests=1 focus=TARGET-BEYOND-100'* ]] &&
         ! request_has_space; then
        pass frozen-provider "third-component Space stayed local and sent no spaced query"
      else
        fail frozen-provider "provider count, local query, or third component was wrong"
      fi
      lem_keys "$session" Enter
      sleep 0.4
      state_before=$(report_count '^STATE ')
      lem_keys "$session" F5
      wait_report_count '^STATE ' $((state_before + 1)) 5 || true
      if wait_report '^ACCEPT label=TARGET-BEYOND-100 buffer=accepted_beyond_cap$' 5 &&
         [[ "$(latest_state)" == 'STATE none buffer=accepted_beyond_cap requests=1' ]]; then
        pass tracked-range-identity "acceptance replaced the full query with insertText"
      else
        fail tracked-range-identity "label/filter/insert identity or replacement range was lost"
      fi
    else
      fail third-component "ordinary Space did not retain local filtering"
    fi
  else
    fail sync-popup "the 120-item provider did not open"
  fi
else
  fail sync-setup "could not prepare the synchronous provider"
fi

# Ordinary Space before the explicit separator retains its normal cancel role.
if run_mx lem-yath-test-orderless-sync-setup && enter_insert; then
  tmux_cmd send-keys -t "$session" -l alp
  if lem_wait_for "$session" 'CANDIDATE-[0-9][0-9][0-9]' 10 >/dev/null; then
    lem_keys "$session" Space
    sleep 0.4
    state_before=$(report_count '^STATE ')
    lem_keys "$session" F5
    wait_report_count '^STATE ' $((state_before + 1)) 5 || true
    if [[ "$(latest_state)" == 'STATE none buffer=alp  requests=1' ]]; then
      pass ordinary-space-cancel "pre-separator Space inserted once and closed completion"
    else
      fail ordinary-space-cancel "ordinary Space unexpectedly entered local filtering"
    fi
  else
    fail ordinary-space-cancel "sync popup did not open"
  fi
else
  fail ordinary-space-setup "could not prepare ordinary-space cancellation"
fi

# Deleting the explicit separator exits local mode. The provider resumes from
# the unspaced token; no intermediate request may contain the separator.
if run_mx lem-yath-test-orderless-sync-setup && enter_insert; then
  tmux_cmd send-keys -t "$session" -l alp
  if lem_wait_for "$session" 'CANDIDATE-[0-9][0-9][0-9]' 10 >/dev/null; then
    lem_keys "$session" M-Space
    lem_keys "$session" BSpace
    if wait_report '^REQUEST sync input="alp" count=2$' 10; then
      state_before=$(report_count '^STATE ')
      lem_keys "$session" F5
      wait_report_count '^STATE ' $((state_before + 1)) 5 || true
      state=$(latest_state)
      if [[ "$state" == *'local=NIL filter=T separator=T raw=120 items=100 popup=T input=alp buffer=alp requests=2'* ]] &&
         ! request_has_space; then
        pass separator-deletion "deleting M-Space resumed an unspaced provider request"
      else
        fail separator-deletion "provider mode or unspaced request ownership was not restored"
      fi
    else
      fail separator-deletion "deleting the separator did not requery the provider"
    fi
  else
    fail separator-deletion "sync popup did not open"
  fi
else
  fail separator-deletion-setup "could not prepare separator deletion"
fi

# Electric delimiters after the separator must pair normally and then refilter
# the frozen raw batch. The unique parenthesis match remains beyond item 100.
if run_mx lem-yath-test-orderless-sync-setup && enter_insert; then
  tmux_cmd send-keys -t "$session" -l alp
  if lem_wait_for "$session" 'CANDIDATE-[0-9][0-9][0-9]' 10 >/dev/null; then
    lem_keys "$session" M-Space
    tmux_cmd send-keys -t "$session" -l '('
    if lem_wait_for "$session" 'TARGET-BEYOND-100' 10 >/dev/null; then
      state_before=$(report_count '^STATE ')
      lem_keys "$session" F5
      wait_report_count '^STATE ' $((state_before + 1)) 5 || true
      state=$(latest_state)
      if [[ "$state" == *'local=T filter=T separator=T raw=120 items=1 popup=T input=alp ( buffer=alp () requests=1 focus=TARGET-BEYOND-100'* ]] &&
         ! request_has_space; then
        pass electric-local-refresh "paired delimiter retained local context without a provider query"
      else
        fail electric-local-refresh "paired buffer, context, or provider count was wrong"
      fi
    else
      fail electric-local-refresh "electric delimiter closed the local completion popup"
    fi
  else
    fail electric-local-refresh "sync popup did not open"
  fi
else
  fail electric-local-setup "could not prepare electric local filtering"
fi

# Paredit close before a non-whitespace character must leave local completion
# before structurally moving across the enclosing close. The buffer stays
# balanced and the cursor lands after the existing parenthesis.
if run_mx lem-yath-test-orderless-lisp-close-setup &&
   wait_report '^SETUP lisp-close paredit=T$' 10 &&
   lem_wait_for "$session" 'LISP-FIRST' 10 >/dev/null; then
  lem_keys "$session" M-Space
  tmux_cmd send-keys -t "$session" -l ')'
  sleep 0.4
  lisp_state_before=$(report_count '^LISP-STATE ')
  lem_keys "$session" F7
  wait_report_count '^LISP-STATE ' $((lisp_state_before + 1)) 5 || true
  lisp_state=$(grep '^LISP-STATE ' "$LEM_YATH_ORDERLESS_COMPLETION_REPORT" |
    tail -n 1)
  if [[ "$lisp_state" == 'LISP-STATE buffer=(alp X) point=7 paredit=T context=NIL requests=1' ]] &&
     [ "$(report_count '^REQUEST lisp ')" -eq 1 ]; then
    pass paredit-close-local-exit "non-whitespace Paredit close ended local completion structurally"
  else
    fail paredit-close-local-exit "Paredit close left the context active or changed the form"
  fi
else
  fail paredit-close-local-setup "could not prepare Lisp local completion"
fi

# A zero-result local filter keeps the context alive; Backspace must reopen it
# from the frozen batch without another provider call.
if run_mx lem-yath-test-orderless-sync-setup && enter_insert; then
  tmux_cmd send-keys -t "$session" -l alp
  if lem_wait_for "$session" 'CANDIDATE-[0-9][0-9][0-9]' 10 >/dev/null; then
    lem_keys "$session" M-Space
    tmux_cmd send-keys -t "$session" -l z
    sleep 0.5
    state_before=$(report_count '^STATE ')
    lem_keys "$session" F5
    wait_report_count '^STATE ' $((state_before + 1)) 5 || true
    no_match_state=$(latest_state)
    lem_keys "$session" BSpace
    if lem_wait_for "$session" 'CANDIDATE-[0-9][0-9][0-9]' 10 >/dev/null; then
      state_before=$(report_count '^STATE ')
      lem_keys "$session" F5
      wait_report_count '^STATE ' $((state_before + 1)) 5 || true
      recovered_state=$(latest_state)
      if [[ "$no_match_state" == *'local=T filter=T separator=T raw=120 items=0 popup=NIL input=alp z buffer=alp z requests=1'* ]] &&
         [[ "$recovered_state" == *'local=T filter=T separator=T raw=120 items=100 popup=T input=alp  buffer=alp  requests=1'* ]]; then
        pass zero-match-recovery "Backspace reopened the frozen batch after zero results"
      else
        fail zero-match-recovery "zero-result context or recovered popup state was wrong"
      fi
    else
      fail zero-match-recovery "Backspace did not reopen candidates"
    fi
  else
    fail zero-match-recovery "sync popup did not open"
  fi
else
  fail zero-match-setup "could not prepare zero-match recovery"
fi

# Freeze an older async batch while a newer request is pending. Its late
# callback must not replace the locally filtered candidates.
if run_mx lem-yath-test-orderless-async-setup && enter_insert; then
  tmux_cmd send-keys -t "$session" -l asy
  if lem_wait_for "$session" 'ASYNC-FROZEN' 10 >/dev/null &&
     wait_report '^REQUEST async input="asy" count=1$' 10; then
    tmux_cmd send-keys -t "$session" -l n
    if wait_report '^REQUEST async input="asyn" count=2$' 10; then
      lem_keys "$session" M-Space
      tmux_cmd send-keys -t "$session" -l target
      if lem_wait_for "$session" 'ASYNC-FROZEN' 10 >/dev/null; then
        lem_keys "$session" F6
        wait_report '^DELIVER stale input=asyn$' 5 || true
        sleep 0.5
        screen=$(lem_capture "$session")
        state_before=$(report_count '^STATE ')
        lem_keys "$session" F5
        wait_report_count '^STATE ' $((state_before + 1)) 5 || true
        state=$(latest_state)
        if grep -q 'ASYNC-FROZEN' <<<"$screen" &&
           ! grep -q 'ASYNC-STALE-RESPONSE' <<<"$screen" &&
           [[ "$state" == *'local=T filter=T separator=T raw=2 items=1 popup=T input=asyn target buffer=asyn target requests=2 focus=ASYNC-FROZEN'* ]] &&
           ! request_has_space; then
          pass stale-after-separator "late async delivery could not replace the frozen generation"
        else
          fail stale-after-separator "stale async response changed local completion"
        fi
        lem_keys "$session" Enter
        if wait_report '^ACCEPT label=ASYNC-FROZEN buffer=async_frozen_insert$' 5; then
          pass async-range "frozen async acceptance replaced the complete tracked input"
        else
          fail async-range "frozen async item lost its original replacement range"
        fi
      else
        fail stale-after-separator "local async target did not appear"
      fi
    else
      fail stale-after-separator "the pending asyn generation was not captured"
    fi
  else
    fail async-popup "initial async batch did not open"
  fi
else
  fail async-setup "could not prepare the async provider"
fi

# Explicit/manual run-completion must inherit the same ordinary-buffer options.
if run_mx lem-yath-test-orderless-manual-setup &&
   wait_report '^SETUP manual$' 10 &&
   lem_wait_for "$session" 'MANUAL-SPECIAL' 10 >/dev/null; then
  lem_keys "$session" M-Space
  tmux_cmd send-keys -t "$session" -l special
  if lem_wait_for "$session" 'MANUAL-SPECIAL' 10 >/dev/null; then
    lem_keys "$session" Enter
    if wait_report '^ACCEPT label=MANUAL-SPECIAL buffer=manA$' 5; then
      pass manual-completion "manual completion used the separator and insertText path"
    else
      fail manual-completion "manual completion did not preserve the tracked range"
    fi
  else
    fail manual-completion "manual local filtering did not retain its target"
  fi
else
  fail manual-setup "manual completion did not open"
fi

# The first item has an explicit subrange extending to buffer end; the second
# has no range and therefore resolves to the symbol at point. Selecting row two
# after M-Space must use its captured nil/default range, not row one's range.
if run_mx lem-yath-test-orderless-range-setup &&
   wait_report '^SETUP range$' 10 &&
   lem_wait_for "$session" 'RANGE-EXPLICIT' 10 >/dev/null &&
   lem_wait_for "$session" 'RANGE-NIL' 10 >/dev/null; then
  lem_keys "$session" M-Space
  lem_keys "$session" C-n
  state_before=$(report_count '^STATE ')
  lem_keys "$session" F5
  wait_report_count '^STATE ' $((state_before + 1)) 5 || true
  range_state=$(latest_state)
  if [[ "$range_state" == *'local=T filter=T separator=T raw=2 items=2 popup=T input=token  buffer=XXtoken  SUFFIX requests=1 focus=RANGE-NIL'* ]]; then
    lem_keys "$session" Enter
    if wait_report '^ACCEPT label=RANGE-NIL buffer=nil_second SUFFIX$' 5; then
      pass mixed-item-ranges "selected nil-range item retained its provider-resolved range"
    else
      fail mixed-item-ranges "selected row inherited the first item range"
    fi
  else
    fail mixed-item-ranges "could not focus the nil-range second item in local mode"
  fi
else
  fail mixed-item-range-setup "mixed explicit/nil range popup did not open"
fi

# A dabbrev context owns its provider for its lifetime. Typing slash ends that
# context, then a new automatic file context starts with native path matching.
if run_mx lem-yath-test-orderless-category-setup && enter_insert; then
  tmux_cmd send-keys -t "$session" -l abc
  if lem_wait_for "$session" 'abcDabbrevCandidate' 10 >/dev/null; then
    state_before=$(report_count '^STATE ')
    lem_keys "$session" F5
    wait_report_count '^STATE ' $((state_before + 1)) 5 || true
    dabbrev_state=$(latest_state)
    tmux_cmd send-keys -t "$session" -l '/'
    if lem_wait_for "$session" 'native-file.txt' 10 >/dev/null; then
      state_before=$(report_count '^STATE ')
      lem_keys "$session" F5
      wait_report_count '^STATE ' $((state_before + 1)) 5 || true
      file_state=$(latest_state)
      screen=$(lem_capture "$session")
      if [[ "$dabbrev_state" == *'local=NIL filter=T separator=T'*'input=abc buffer=abc'* ]] &&
         [[ "$file_state" == *'local=NIL filter=NIL separator=NIL raw=2 items=2 popup=T input= buffer=abc/'* ]] &&
         ! grep -q 'abcDabbrevCandidate' <<<"$screen"; then
        pass category-transition "slash replaced dabbrev with a native file context"
      else
        fail category-transition "dabbrev provider drifted into file completion"
      fi
    else
      fail category-transition "native file context did not restart after slash"
    fi
  else
    fail category-transition "initial dabbrev context did not open"
  fi
else
  fail category-transition-setup "could not prepare dabbrev-to-file transition"
fi

# File-at-point completion keeps its native path matcher and cannot enter the
# ordinary-buffer Orderless separator mode.
if run_mx lem-yath-test-orderless-file-setup && enter_insert; then
  tmux_cmd send-keys -t "$session" -l ./a
  if lem_wait_for "$session" 'alpha-file.txt' 10 >/dev/null; then
    state_before=$(report_count '^STATE ')
    lem_keys "$session" F5
    wait_report_count '^STATE ' $((state_before + 1)) 5 || true
    native_state=$(latest_state)
    lem_keys "$session" M-Space
    sleep 0.4
    state_before=$(report_count '^STATE ')
    lem_keys "$session" F5
    wait_report_count '^STATE ' $((state_before + 1)) 5 || true
    if [[ "$native_state" == *'local=NIL filter=NIL separator=NIL'* ]] &&
       [[ "$(latest_state)" == 'STATE none buffer=./a  requests=0' ]]; then
      pass file-isolation "file completion retained native matching and M-Space cancellation"
    else
      fail file-isolation "file completion inherited ordinary Orderless options"
    fi
  else
    fail file-isolation "file-at-point popup did not open"
  fi
else
  fail file-setup "could not prepare file completion"
fi

# Prompt contexts continue to use their configured Prescient path. M-Space is
# query input there, and the context has no ordinary Orderless filter/separator.
if invoke_prompt; then
  tmux_cmd send-keys -t "$session" -l orderless
  lem_keys "$session" M-Space
  tmux_cmd send-keys -t "$session" -l alpha
  sleep 0.7
  state_before=$(report_count '^STATE ')
  lem_keys "$session" F5
  wait_report_count '^STATE ' $((state_before + 1)) 5 || true
  screen=$(lem_capture "$session")
  state=$(latest_state)
  if grep -Fq 'Orderless prompt: orderless alpha' <<<"$screen" &&
     [[ "$state" == *'local=NIL filter='*' separator=NIL '* ]]; then
    pass prompt-isolation "prompt M-Space stayed prompt input outside local filtering"
  else
    fail prompt-isolation "prompt inherited the ordinary Orderless separator"
  fi
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
else
  fail prompt-setup "could not open the prompt isolation fixture"
fi

echo
cat "$LEM_YATH_ORDERLESS_COMPLETION_REPORT" 2>/dev/null || true

if [ "$failed" = 0 ]; then
  echo "ORDERLESS COMPLETION TEST PASSED"
  exit 0
else
  echo "ORDERLESS COMPLETION TEST FAILED"
  exit 1
fi
