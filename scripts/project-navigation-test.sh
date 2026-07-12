#!/usr/bin/env bash
# Real-ncurses coverage for persistent, project-aware navigation workflows.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-project-navigation-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-project-navigation.XXXXXX")"
case "$root" in
  "" | /)
    echo "Refusing unsafe project-navigation test directory: $root" >&2
    exit 1
    ;;
esac

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_HOME="$root/lem-home/"
export LEM_YATH_COMPLETION_STATE_FILE="$root/completion-ranking.sexp"
export LEM_YATH_PROJECT_NAVIGATION_REPORT="$root/report"
export LEM_YATH_PROJECT_NAVIGATION_ALPHA="$root/projects/alpha/"
export LEM_YATH_PROJECT_NAVIGATION_ALPHA_SIBLING="$root/projects/alpha-sibling/"
export LEM_YATH_PROJECT_NAVIGATION_BETA="$root/projects/beta/"
export LEM_YATH_PROJECT_NAVIGATION_GAMMA="$root/projects/gamma/"
export LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_DOT="$root/projects/submodule-dot/"
export LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE="$root/projects/submodule-outside/"
export LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE_TARGET="$root/projects/submodule-outside-target/"
export LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE="$root/projects/submodule-cycle/"
export LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD="$root/projects/submodule-cycle/child/"
export LEM_YATH_PROJECT_NAVIGATION_REQUEST_STATE="$root/request-state/"
export LEM_YATH_PROJECT_NAVIGATION_REQUEST_HELPER="$root/request-helper.sh"
submodule_child="$root/submodule-child"

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" "$LEM_HOME" \
  "$LEM_YATH_PROJECT_NAVIGATION_ALPHA/src" \
  "$LEM_YATH_PROJECT_NAVIGATION_ALPHA/build" \
  "$LEM_YATH_PROJECT_NAVIGATION_ALPHA/ignored-dir" \
  "$LEM_YATH_PROJECT_NAVIGATION_ALPHA_SIBLING/build" \
  "$LEM_YATH_PROJECT_NAVIGATION_BETA" \
  "$LEM_YATH_PROJECT_NAVIGATION_GAMMA" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_DOT" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE_TARGET" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD" \
  "$LEM_YATH_PROJECT_NAVIGATION_REQUEST_STATE" \
  "$submodule_child/nested"
: >"$LEM_YATH_PROJECT_NAVIGATION_REPORT"

printf 'ignored-target.txt\nignored-dir/\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/.gitignore"
printf 'ALPHA MAIN PROJECT\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/alpha-main.txt"
printf 'TRACKED PROJECT TARGET\nSHARED_GREP ALPHA\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/src/tracked-target.txt"
printf 'UNTRACKED PROJECT TARGET\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/src/untracked-target.txt"
printf 'SHARED_GREP TRACKED BUILD\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/build/kept.txt"
printf 'SHARED_GREP IGNORED\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/ignored-target.txt"
printf 'SHARED_GREP IGNORED TREE\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA/ignored-dir/secret.txt"
printf 'SIBLING PROJECT FILE\nSHARED_GREP SIBLING\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_ALPHA_SIBLING/sibling-only.txt"
printf 'BETA MAIN PROJECT\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_BETA/beta-main.txt"
printf 'GAMMA TARGET PROJECT\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_GAMMA/gamma-target.txt"
printf 'SUBMODULE CHILD TARGET\n' \
  >"$submodule_child/nested/child-file.txt"
printf 'OUTSIDE SUBMODULE TARGET\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE_TARGET/outside.txt"
printf 'CYCLE CHILD TARGET\n' \
  >"$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD/child.txt"

printf '%s\n' \
  '[submodule "dot"]' \
  '  path = .' \
  '  url = ../unused' \
  >"$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_DOT/.gitmodules"
printf '%s\n' \
  '[submodule "escape"]' \
  '  path = escape' \
  '  url = ../unused' \
  >"$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE/.gitmodules"
ln -s "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE_TARGET" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE/escape"
printf '%s\n' \
  '[submodule "child"]' \
  '  path = child' \
  '  url = ../unused' \
  >"$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE/.gitmodules"
printf '%s\n' \
  '[submodule "back"]' \
  '  path = back' \
  '  url = ../unused' \
  >"$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD/.gitmodules"
ln -s .. "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD/back"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -uo pipefail' \
  'label=$1' \
  'state=$2' \
  ': >"$state/$label-started"' \
  'deadline=$((SECONDS + 30))' \
  'while [ ! -e "$state/$label-release" ]; do' \
  '  if ((SECONDS >= deadline)); then exit 97; fi' \
  '  sleep 0.02' \
  'done' \
  'printf "%s.txt\\0" "request-$label"' \
  >"$LEM_YATH_PROJECT_NAVIGATION_REQUEST_HELPER"
chmod +x "$LEM_YATH_PROJECT_NAVIGATION_REQUEST_HELPER"

for project in \
  "$LEM_YATH_PROJECT_NAVIGATION_ALPHA" \
  "$LEM_YATH_PROJECT_NAVIGATION_ALPHA_SIBLING" \
  "$LEM_YATH_PROJECT_NAVIGATION_BETA" \
  "$LEM_YATH_PROJECT_NAVIGATION_GAMMA" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_DOT" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_OUTSIDE_TARGET" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE" \
  "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD"; do
  git -C "$project" init -q
done
git -C "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD" \
  config user.name 'Lem Yath Test'
git -C "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD" \
  config user.email 'lem-yath-test@example.invalid'
git -C "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD" add \
  .gitmodules back child.txt
git -C "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE_CHILD" \
  commit -qm 'Add cyclic child fixture'
git -c advice.addEmbeddedRepo=false \
  -C "$LEM_YATH_PROJECT_NAVIGATION_SUBMODULE_CYCLE" add \
  .gitmodules child
git -C "$LEM_YATH_PROJECT_NAVIGATION_ALPHA" add \
  .gitignore alpha-main.txt build/kept.txt src/tracked-target.txt
git -C "$LEM_YATH_PROJECT_NAVIGATION_ALPHA_SIBLING" add sibling-only.txt
git -C "$LEM_YATH_PROJECT_NAVIGATION_BETA" add beta-main.txt
git -C "$LEM_YATH_PROJECT_NAVIGATION_GAMMA" add gamma-target.txt
git -C "$submodule_child" init -q
git -C "$submodule_child" config user.name 'Lem Yath Test'
git -C "$submodule_child" config user.email 'lem-yath-test@example.invalid'
git -C "$submodule_child" add nested/child-file.txt
git -C "$submodule_child" commit -qm 'Add child fixture'
git -c protocol.file.allow=always \
  -C "$LEM_YATH_PROJECT_NAVIGATION_ALPHA" \
  submodule add -q "$submodule_child" vendor/child

source "$here/scripts/tui-driver.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"
KEY_DELAY="${KEY_DELAY:-0.25}"
failed=0
sessions=()

cleanup() {
  local session
  for session in "${sessions[@]:-}"; do
    [ -n "$session" ] && lem_stop "$session"
  done
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-31s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-31s %s\n' "$1" "$2"
  [ -n "${3:-}" ] && lem_capture "$3" 2>/dev/null || true
}

report_count() {
  grep -cE "$1" "$LEM_YATH_PROJECT_NAVIGATION_REPORT" 2>/dev/null || true
}

wait_report_count() {
  local pattern=$1 expected=$2 timeout=${3:-$WAIT_TIMEOUT} index=0
  while ((index < timeout * 4)); do
    if (( $(report_count "$pattern") >= expected )); then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

send_chord() {
  local session=$1
  shift
  local key
  for key in "$@"; do
    lem_keys "$session" "$key"
    sleep "$KEY_DELAY"
  done
}

fixture="$(lem-yath_lisp_string "$here/scripts/project-navigation-fixture.lisp")"

start_phase() {
  local session=$1 phase=$2 ready_before
  shift 2
  ready_before=$(report_count "^READY phase=$phase$")
  export LEM_YATH_PROJECT_NAVIGATION_PHASE="$phase"
  tmux_cmd set-environment -g LEM_YATH_PROJECT_NAVIGATION_PHASE "$phase" \
    2>/dev/null || true
  sessions+=("$session")
  lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$@"
  wait_report_count "^READY phase=$phase$" "$((ready_before + 1))" \
    "$BOOT_TIMEOUT"
}

invoke_mx() {
  local session=$1 command=$2 report_pattern=$3 before
  before=$(report_count "$report_pattern")
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' "$WAIT_TIMEOUT" >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.5
  lem_keys "$session" Enter
  wait_report_count "$report_pattern" "$((before + 1))"
}

submit_completion_prompt() {
  local session=$1 prompt_pattern=$2 index=0
  lem_keys "$session" Enter
  sleep 0.3
  while ((index < 8)); do
    if ! lem_capture "$session" | grep -qE "$prompt_pattern"; then
      return 0
    fi
    sleep 0.1
    index=$((index + 1))
  done
  return 1
}

register_session="lem-yath-project-register-$id"
if start_phase "$register_session" register \
     "$LEM_YATH_PROJECT_NAVIGATION_ALPHA/alpha-main.txt" &&
   lem_wait_for "$register_session" 'ALPHA MAIN PROJECT' "$BOOT_TIMEOUT" \
     >/dev/null; then
  pass register-boot 'clean-profile Lem opened the current Alpha project'
else
  fail register-boot 'registration phase did not initialize' "$register_session"
fi

if invoke_mx "$register_session" \
     lem-yath-test-project-navigation-record-history \
     '^HISTORY phase=register sample=1 ' &&
   grep -q '^HISTORY phase=register sample=1 roots=alpha count=1 alpha=1 beta=0 gamma=0 disk=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass current-project-registration \
    'opening one current-project file registered and persisted Alpha'
else
  fail current-project-registration \
    'clean-profile Alpha registration diverged' "$register_session"
fi

if invoke_mx "$register_session" \
     lem-yath-test-project-navigation-open-beta '^OPEN label=beta ' &&
   lem_wait_for "$register_session" 'BETA MAIN PROJECT' "$WAIT_TIMEOUT" \
     >/dev/null; then
  pass second-project-registration 'a real file visit registered Beta'
else
  fail second-project-registration 'Beta did not open through the real hook' \
    "$register_session"
fi

if invoke_mx "$register_session" \
     lem-yath-test-project-navigation-record-history \
     '^HISTORY phase=register sample=2 ' &&
   grep -q '^HISTORY phase=register sample=2 roots=beta,alpha count=2 alpha=1 beta=1 gamma=0 disk=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-mru-order 'Beta moved ahead of Alpha without duplication'
else
  fail project-mru-order 'in-process project MRU order diverged' \
    "$register_session"
fi

lem_stop "$register_session"
sleep 0.5

verify_session="lem-yath-project-verify-$id"
if start_phase "$verify_session" verify &&
   lem_wait_for "$verify_session" 'NORMAL|Dashboard' "$BOOT_TIMEOUT" \
     >/dev/null; then
  pass verify-boot 'fresh Lem process loaded the shared hermetic profile'
else
  fail verify-boot 'verification phase did not initialize' "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-record-history \
     '^HISTORY phase=verify sample=1 ' &&
   grep -q '^HISTORY phase=verify sample=1 roots=beta,alpha count=2 alpha=1 beta=1 gamma=0 disk=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-mru-persistence \
    'a fresh process restored the persisted Beta,Alpha MRU'
else
  fail project-mru-persistence 'fresh-process project history diverged' \
    "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-static-checks '^STATIC ' &&
   grep -q '^STATIC normal=yes visual=yes pf=yes pg=yes pp=yes space=yes leader-tree=yes emacs-dispatch=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT" &&
   grep -q '^REGEXP escaped-alternation=yes raw-alternation=yes leading-close-class=yes escaped-close-class=yes negated-close-class=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-leader-bindings \
    'leader maps and project-dispatch keys match Emacs; regexp conversion is exact'
else
  fail project-leader-bindings 'project leader bindings diverged' \
    "$verify_session"
fi

request_race_before=$(report_count '^REQUEST-RACE ')
lem_keys "$verify_session" Escape
sleep 0.2
lem_keys "$verify_session" F9
if wait_report_count '^REQUEST-RACE ' "$((request_race_before + 1))" 45 &&
   grep -q '^REQUEST-RACE a-cancelled=yes b-live=yes a-launch=no b-owned=yes a-published=no b-published=yes propagated=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-request-cancellation \
    'cancellation is request-local and stale work cannot launch or publish'
else
  fail project-request-cancellation \
    'overlapping project request ownership diverged' "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-setup-buffers '^SETUP ' &&
   lem_wait_for "$verify_session" 'ALPHA MAIN PROJECT' "$WAIT_TIMEOUT" \
     >/dev/null; then
  pass buffer-setup 'file and non-file sibling fixtures were created'
else
  fail buffer-setup 'project buffer fixture setup failed' "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-record-candidates '^CANDIDATES ' &&
   grep -q '^CANDIDATES root=alpha tracked=yes untracked=yes ignored=no ignored-tree=no git-internal=no sibling=no relative=yes unique=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass git-project-candidates \
    'Git candidates include tracked and untracked files but no ignored escape'
else
  fail git-project-candidates 'Git project candidate contract diverged' \
    "$verify_session"
fi

if grep -q '^SUBMODULE file=yes gitlink=no merged-root=alpha$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass git-submodule-parity \
    'initialized child files merge into Alpha without exposing the gitlink'
else
  fail git-submodule-parity \
    'Git submodule candidates or merged root diverged' "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-submodule-safety \
     '^SUBMODULE-SAFETY ' &&
   grep -q '^SUBMODULE-SAFETY dot=yes outside=yes cycle=yes visited-once=yes bounded=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass git-submodule-safety \
    'malformed, escaping, and cyclic submodule roots are bounded and unique'
else
  fail git-submodule-safety \
    'submodule containment or cycle handling diverged' "$verify_session"
fi

if invoke_mx "$verify_session" \
     lem-yath-test-project-navigation-record-buffers '^BUFFERS ' &&
   grep -q '^BUFFERS root=alpha alpha-file=yes alpha-nonfile=yes sibling-file=no sibling-nonfile=no fileless=yes exact=yes$' \
     "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
  pass project-buffer-membership \
    'buffer-directory includes non-files and exactly excludes alpha-sibling'
else
  fail project-buffer-membership 'project buffer containment diverged' \
    "$verify_session"
fi

lem_keys "$verify_session" Escape
sleep 0.2
send_chord "$verify_session" Space Space
if lem_wait_for "$verify_session" 'Project buffer( \(current\))?:' "$WAIT_TIMEOUT" \
     >/dev/null; then
  buffer_screen=$(lem_capture "$verify_session")
  if grep -Fq 'alpha-main.txt' <<<"$buffer_screen" &&
     grep -Fq '*alpha-build*' <<<"$buffer_screen" &&
     ! grep -Fq 'sibling-only.txt' <<<"$buffer_screen" &&
     ! grep -Fq '*sibling-build*' <<<"$buffer_screen"; then
    pass spc-space-candidates \
      'SPC SPC rendered Alpha file and non-file candidates only'
  else
    fail spc-space-candidates 'SPC SPC rendered the wrong project buffers' \
      "$verify_session"
  fi
  tmux_cmd send-keys -t "$verify_session" -l 'alpha-build'
  sleep 0.4
  submit_completion_prompt "$verify_session" 'Project buffer( \(current\))?:'
  if lem_wait_for "$verify_session" 'ALPHA NONFILE BUILD BUFFER' \
       "$WAIT_TIMEOUT" >/dev/null; then
    before=$(report_count '^CURRENT label=spc-space ')
    lem_keys "$verify_session" F5
    if wait_report_count '^CURRENT label=spc-space ' "$((before + 1))" &&
       grep -q '^CURRENT label=spc-space root=alpha name=\*alpha-build\* file=none directory=build/$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-space-selection \
        'SPC SPC selected a fileless buffer from its buffer-directory'
    else
      fail spc-space-selection 'SPC SPC selected the wrong buffer identity' \
        "$verify_session"
    fi
  else
    fail spc-space-selection 'SPC SPC did not open the non-file buffer' \
      "$verify_session"
  fi
else
  fail spc-space-binding 'SPC SPC did not open the project-buffer prompt' \
    "$verify_session"
fi

lem_keys "$verify_session" Escape
sleep 0.2
send_chord "$verify_session" Space p f
if lem_wait_for "$verify_session" 'Project file( \(current\))?:' "$WAIT_TIMEOUT" >/dev/null &&
   lem_wait_for "$verify_session" 'src/tracked-target\.txt' "$WAIT_TIMEOUT" \
     >/dev/null &&
   lem_wait_for "$verify_session" 'src/untracked-target\.txt' "$WAIT_TIMEOUT" \
     >/dev/null; then
  file_screen=$(lem_capture "$verify_session")
  if ! grep -Fq 'ignored-target.txt' <<<"$file_screen" &&
     ! grep -Fq 'ignored-dir/secret.txt' <<<"$file_screen" &&
     ! grep -Fq '.git/' <<<"$file_screen"; then
    pass spc-p-f-candidates \
      'SPC p f exposed tracked and untracked Git candidates only'
  else
    fail spc-p-f-candidates 'SPC p f exposed an ignored or internal path' \
      "$verify_session"
  fi
  tmux_cmd send-keys -t "$verify_session" -l 'untracked-target'
  sleep 0.4
  submit_completion_prompt "$verify_session" 'Project file( \(current\))?:'
  if lem_wait_for "$verify_session" 'UNTRACKED PROJECT TARGET' \
       "$WAIT_TIMEOUT" >/dev/null; then
    before=$(report_count '^CURRENT label=spc-p-f ')
    lem_keys "$verify_session" F6
    if wait_report_count '^CURRENT label=spc-p-f ' "$((before + 1))" &&
       grep -q '^CURRENT label=spc-p-f root=alpha name=untracked-target\.txt file=src/untracked-target\.txt directory=src/$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-f-selection \
        'SPC p f resolved Alpha from a non-file buffer and opened its file'
    else
      fail spc-p-f-selection 'SPC p f opened the wrong file identity' \
        "$verify_session"
    fi
  else
    fail spc-p-f-selection 'SPC p f did not open the untracked target' \
      "$verify_session"
  fi
else
  fail spc-p-f-binding 'SPC p f did not expose both expected candidates' \
    "$verify_session"
fi

lem_keys "$verify_session" Escape
sleep 0.2
send_chord "$verify_session" Space p g
if lem_wait_for "$verify_session" 'Project regexp:' "$WAIT_TIMEOUT" \
     >/dev/null; then
  tmux_cmd send-keys -t "$verify_session" -l 'SHARED_GREP'
  lem_keys "$verify_session" Enter
  if lem_wait_for "$verify_session" 'SHARED_GREP ALPHA' "$WAIT_TIMEOUT" \
       >/dev/null; then
    grep_screen=$(lem_capture "$verify_session")
    if ! grep -Fq 'SHARED_GREP SIBLING' <<<"$grep_screen" &&
       ! grep -Fq 'SHARED_GREP IGNORED' <<<"$grep_screen"; then
      pass spc-p-g-results \
        'SPC p g stayed inside Alpha and honored ignored paths'
    else
      fail spc-p-g-results 'project grep leaked a sibling or ignored result' \
        "$verify_session"
    fi
    before=$(report_count '^GREP ')
    lem_keys "$verify_session" F8
    if wait_report_count '^GREP ' "$((before + 1))" &&
       grep -q '^GREP alpha=yes tracked-build=yes sibling=no ignored=no matches=2$' \
         "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
      pass spc-p-g-buffer \
        'project grep includes tracked build files and excludes ignored paths'
    else
      fail spc-p-g-buffer 'the project grep result buffer diverged' \
        "$verify_session"
    fi
  else
    fail spc-p-g-results 'SPC p g produced no Alpha match' "$verify_session"
  fi
else
  fail spc-p-g-binding 'SPC p g did not open the regexp prompt' \
    "$verify_session"
fi

lem_keys "$verify_session" Escape
sleep 0.4
lem_keys "$verify_session" Escape
sleep 0.2
send_chord "$verify_session" Space p p
if lem_wait_for "$verify_session" 'Project( \(current\))?:' "$WAIT_TIMEOUT" >/dev/null; then
  tmux_cmd send-keys -t "$verify_session" -l 'choose'
  if lem_wait_for "$verify_session" 'choose a dir' "$WAIT_TIMEOUT" \
       >/dev/null; then
    submit_completion_prompt "$verify_session" 'Project( \(current\))?:'
    if lem_wait_for "$verify_session" 'Project directory.*:' "$WAIT_TIMEOUT" \
         >/dev/null; then
      lem_keys "$verify_session" F4
      if lem_wait_for "$verify_session" 'Project command' "$WAIT_TIMEOUT" \
           >/dev/null &&
         lem_wait_for "$verify_session" 'find file' "$WAIT_TIMEOUT" \
           >/dev/null &&
         lem_wait_for "$verify_session" 'find regexp' "$WAIT_TIMEOUT" \
           >/dev/null; then
        pass spc-p-p-dispatch \
          'SPC p p accepted an arbitrary directory and showed its dispatch'
        lem_keys "$verify_session" f
        if lem_wait_for "$verify_session" 'Project file( \(current\))?:' "$WAIT_TIMEOUT" \
             >/dev/null; then
          tmux_cmd send-keys -t "$verify_session" -l 'gamma-target'
          sleep 0.3
          submit_completion_prompt "$verify_session" 'Project file( \(current\))?:'
          if lem_wait_for "$verify_session" 'GAMMA TARGET PROJECT' \
               "$WAIT_TIMEOUT" >/dev/null; then
            before=$(report_count '^CURRENT label=spc-p-p ')
            lem_keys "$verify_session" F7
            if wait_report_count '^CURRENT label=spc-p-p ' \
                 "$((before + 1))" &&
               grep -q '^CURRENT label=spc-p-p root=gamma name=gamma-target\.txt file=gamma-target\.txt directory=\.$' \
                 "$LEM_YATH_PROJECT_NAVIGATION_REPORT" &&
               grep -q '^SWITCH dispatch=find-file gamma-known=yes mru-first=gamma$' \
                 "$LEM_YATH_PROJECT_NAVIGATION_REPORT"; then
              pass spc-p-p-selection \
                'the dispatch ran find-file against Gamma and promoted its MRU'
            else
              fail spc-p-p-selection \
                'project switch dispatch retained the wrong project root' \
                "$verify_session"
            fi
          else
            fail spc-p-p-selection \
              'Gamma dispatch did not open gamma-target.txt' "$verify_session"
          fi
        else
          fail spc-p-p-find 'dispatch f did not open a project-file prompt' \
            "$verify_session"
        fi
      else
        fail spc-p-p-dispatch 'project switch dispatch was absent or incomplete' \
          "$verify_session"
      fi
    else
      fail spc-p-p-directory 'arbitrary-directory choice did not prompt' \
        "$verify_session"
    fi
  else
    fail spc-p-p-choice 'project picker omitted its arbitrary-directory row' \
      "$verify_session"
  fi
else
  fail spc-p-p-binding 'SPC p p did not open the project picker' \
    "$verify_session"
fi

printf '\n'
cat "$LEM_YATH_PROJECT_NAVIGATION_REPORT" 2>/dev/null || true
if ((failed)); then
  echo 'PROJECT NAVIGATION TEST FAILED'
  exit 1
fi

echo 'PROJECT NAVIGATION TEST PASSED'
