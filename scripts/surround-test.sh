#!/usr/bin/env bash
# Real-ncurses regression coverage for balanced, fail-closed surround edits.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-surround-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-surround.XXXXXX")"
session="lem-yath-surround-$id"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_SURROUND_REPORT="$root/report"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR"
: >"$LEM_YATH_SURROUND_REPORT"

source "$here/scripts/tui-driver.sh"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-15}"
failed=0

cleanup() {
  lem_stop "$session" || true
  rm -rf -- "$root"
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %-28s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-28s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
}

report_count() {
  grep -cE "$1" "$LEM_YATH_SURROUND_REPORT" 2>/dev/null || true
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

hex_of() {
  printf '%s' "$1" | od -An -tx1 | tr -d ' \n' | tr '[:lower:]' '[:upper:]'
}

invoke_setup() {
  local command=$1 label=$2 before
  before=$(report_count "^SETUP label=$label ")
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" Escape
  sleep 0.2
  lem_keys "$session" M-x
  lem_wait_for "$session" 'Command:' "$WAIT_TIMEOUT" >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.4
  lem_keys "$session" Enter
  wait_report_count "^SETUP label=$label " "$((before + 1))"
}

record_result() {
  local label=$1 before
  before=$(report_count "^RESULT label=$label ")
  lem_keys "$session" F12
  wait_report_count "^RESULT label=$label " "$((before + 1))"
}

last_result() {
  grep "^RESULT label=$1 " "$LEM_YATH_SURROUND_REPORT" | tail -1
}

assert_result() {
  local name=$1 label=$2 text=$3 modified=$4 anchor=$5 expected_point=${6:-} line hex
  line=$(last_result "$label")
  hex=$(hex_of "$text")
  if [[ "$line" == *"text-hex=$hex "* &&
        "$line" == *"anchor=$anchor modified=$modified mark=no state=NORMAL"* &&
        ( -z "$expected_point" || "$line" == *" point=$expected_point "* ) ]]; then
    pass "$name" "$label matched text, cursor/mark contract, and Vi state"
  else
    fail "$name" "unexpected result: $line"
  fi
}

setup_and_keys() {
  local command=$1 label=$2
  shift 2
  invoke_setup "$command" "$label" || return 1
  lem_keys "$session" "$@"
  sleep 0.35
  record_result "$label"
}

fixture="$(lem-yath_lisp_string "$here/scripts/surround-fixture.lisp")"
file="$WORKDIR/surround.py"
: >"$file"
lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$file"

if ! lem_wait_for "$session" 'NORMAL' "$BOOT_TIMEOUT" >/dev/null ||
   ! wait_report_count '^READY$' 1 "$BOOT_TIMEOUT"; then
  fail boot 'configured Lem did not load the surround fixture'
  exit 1
fi
pass boot 'configured Lem opened the syntax-aware Python fixture'

if setup_and_keys lem-yath-test-surround-nested-inner nested-inner d s '('; then
  assert_result nested-inner nested-inner '(alpha omega)' yes yes
  lem_keys "$session" u
  sleep 0.25
  record_result nested-inner &&
    assert_result nested-inner-undo nested-inner '((alpha) omega)' no no
else
  fail nested-inner 'nested-inner command did not complete'
fi

if setup_and_keys lem-yath-test-surround-nested-outer nested-outer d s '('; then
  assert_result nested-outer nested-outer '(alpha) omega' yes yes
else
  fail nested-outer 'nested-outer command did not complete'
fi

if setup_and_keys lem-yath-test-surround-string-decoy string-decoy d s '('; then
  assert_result string-decoy string-decoy 'alpha, ")", omega' yes yes
else
  fail string-decoy 'string-decoy command did not complete'
fi

if setup_and_keys lem-yath-test-surround-string-target string-target d s '('; then
  assert_result string-target string-target 'call "alpha"' yes yes
else
  fail string-target 'code enclosure around a string target was not selected'
fi

if setup_and_keys lem-yath-test-surround-mixed-delimiters \
    mixed-delimiters d s '{'; then
  assert_result mixed-delimiters mixed-delimiters '[alpha]' yes yes
else
  fail mixed-delimiters 'mixed nested delimiters were not resolved'
fi

comment_result=$'\n  alpha\n  # ) decoy\n  omega\n\n'
if setup_and_keys lem-yath-test-surround-comment-decoy comment-decoy d s '('; then
  assert_result comment-decoy comment-decoy "$comment_result" yes yes
else
  fail comment-decoy 'comment-decoy command did not complete'
fi

escaped_source='"alpha \" beta"'
escaped_result='alpha \" beta'
if setup_and_keys lem-yath-test-surround-escaped-quote escaped-quote d s '"'; then
  assert_result escaped-quote escaped-quote "$escaped_result" yes yes
  lem_keys "$session" u
  sleep 0.25
  record_result escaped-quote &&
    assert_result escaped-quote-undo escaped-quote "$escaped_source" no no
else
  fail escaped-quote 'escaped-quote command did not complete'
fi

if setup_and_keys lem-yath-test-surround-triple-quote triple-quote d s '"'; then
  assert_result triple-quote-fail-closed triple-quote '"""alpha"""' no yes
else
  fail triple-quote-fail-closed 'triple quote command did not return safely'
fi

if setup_and_keys lem-yath-test-surround-triple-quote-second \
    triple-quote-second d s '"'; then
  assert_result triple-quote-second-fail-closed \
    triple-quote-second '"""alpha"""' no yes
else
  fail triple-quote-second-fail-closed \
    'second triple quote command did not return safely'
fi

if setup_and_keys lem-yath-test-surround-triple-quote-body \
    triple-quote-body d s '"'; then
  assert_result triple-quote-body-fail-closed \
    triple-quote-body '"""alpha"""' no yes
else
  fail triple-quote-body-fail-closed \
    'triple quote body command did not return safely'
fi

if setup_and_keys lem-yath-test-surround-padded-change padded-change c s '(' ']'; then
  assert_result padded-change padded-change '[alpha]' yes yes
  lem_keys "$session" u
  sleep 0.25
  record_result padded-change &&
    assert_result padded-change-undo padded-change '( alpha )' no no
else
  fail padded-change 'padded change did not complete'
fi

if setup_and_keys lem-yath-test-surround-compact-change compact-change c s ']' '('; then
  assert_result compact-change compact-change '( alpha )' yes yes
else
  fail compact-change 'compact change did not complete'
fi

if setup_and_keys lem-yath-test-surround-single-padding single-padding d s '('; then
  assert_result single-padding single-padding '' yes no
else
  fail single-padding 'single-padding delete did not complete'
fi

if setup_and_keys lem-yath-test-surround-malformed malformed d s '('; then
  assert_result malformed-delete malformed '(alpha' no yes
  lem_keys "$session" u
  sleep 0.25
  record_result malformed &&
    assert_result malformed-no-undo malformed '(alpha' no yes
else
  fail malformed-delete 'malformed delete did not return cleanly'
fi

if setup_and_keys lem-yath-test-surround-malformed malformed c s '('; then
  assert_result malformed-change malformed '(alpha' no yes
else
  fail malformed-change 'malformed change prompted for a replacement or stalled'
fi

if setup_and_keys lem-yath-test-surround-protected protected d s '('; then
  assert_result protected-preflight protected '(alpha)' no yes
else
  fail protected-preflight 'read-only preflight did not return control'
fi

if setup_and_keys lem-yath-test-surround-protected-inner \
    protected-inner c s ')' ']'; then
  assert_result protected-inner-change protected-inner '(alpha)' no yes
  lem_keys "$session" u
  sleep 0.25
  record_result protected-inner &&
    assert_result protected-inner-no-undo protected-inner '(alpha)' no yes
else
  fail protected-inner-change 'protected inner change partially mutated'
fi

if setup_and_keys lem-yath-test-surround-protected-suffix \
    protected-suffix c s ')' ']'; then
  assert_result protected-suffix-change protected-suffix '(alpha)Z' no yes
  lem_keys "$session" u
  sleep 0.25
  record_result protected-suffix &&
    assert_result protected-suffix-no-undo protected-suffix '(alpha)Z' no yes
else
  fail protected-suffix-change 'protected suffix change partially mutated'
fi

lisp_character_source='(list #\( alpha #\) tail)'
lisp_character_result='list #\( alpha #\) tail'
if setup_and_keys \
    lem-yath-test-surround-lisp-character-literals \
    lisp-character-literals d s '('; then
  assert_result lisp-character-literals lisp-character-literals \
    "$lisp_character_result" yes yes
  lem_keys "$session" u
  sleep 0.25
  record_result lisp-character-literals &&
    assert_result lisp-character-literals-undo lisp-character-literals \
      "$lisp_character_source" no no
else
  fail lisp-character-literals 'Lisp character literal case did not complete'
fi

if setup_and_keys lem-yath-test-surround-lisp-fence-decoy \
    lisp-fence-decoy d s '('; then
  assert_result lisp-fence-decoy lisp-fence-decoy \
    'list |foo(bar| alpha' yes yes
else
  fail lisp-fence-decoy 'Lisp fence delimiter entered the code stack'
fi

if setup_and_keys lem-yath-test-surround-lisp-fence-delete \
    lisp-fence-delete d s '|'; then
  assert_result lisp-fence-delete lisp-fence-delete '(foo bar)' yes yes
else
  fail lisp-fence-delete 'symmetric fence surround did not complete'
fi

if invoke_setup lem-yath-test-surround-add-form add-form; then
  lem_keys "$session" y s i w t
  sleep 0.2
  tmux_cmd send-keys -t "$session" -l 'em>'
  sleep 0.35
  record_result add-form &&
    assert_result tag-add add-form '<em>alpha</em> beta' yes yes
else
  fail tag-add 'tag insertion fixture did not open'
fi

if invoke_setup lem-yath-test-surround-add-form add-form; then
  lem_keys "$session" y s i w f
  lem_wait_for "$session" 'Function:' "$WAIT_TIMEOUT" >/dev/null || true
  tmux_cmd send-keys -t "$session" -l 'wrap'
  lem_keys "$session" Enter
  sleep 0.35
  record_result add-form &&
    assert_result function-add add-form 'wrap(alpha) beta' yes yes
else
  fail function-add 'function insertion fixture did not open'
fi

if invoke_setup lem-yath-test-surround-add-form add-form; then
  lem_keys "$session" y s i w C-f
  lem_wait_for "$session" 'Prefix function:' "$WAIT_TIMEOUT" >/dev/null || true
  tmux_cmd send-keys -t "$session" -l 'when'
  lem_keys "$session" Enter
  sleep 0.35
  record_result add-form &&
    assert_result prefix-function-add add-form '(when alpha) beta' yes yes
else
  fail prefix-function-add 'prefix-function insertion fixture did not open'
fi

if setup_and_keys lem-yath-test-surround-add-form add-form y s i w '#'; then
  assert_result hash-pair-add add-form '#{alpha} beta' yes yes
else
  fail hash-pair-add 'hash-pair insertion did not complete'
fi

block_source=$'aa11zz\nbb22yy\ncc33xx\n'
block_compact=$'aa[11]zz\nbb[22]yy\ncc[33]xx\n'
if setup_and_keys lem-yath-test-surround-block-forward \
    block-forward C-v j j l S ']'; then
  assert_result block-forward block-forward "$block_compact" yes no 3
  lem_keys "$session" u
  sleep 0.25
  record_result block-forward &&
    assert_result block-forward-one-undo block-forward "$block_source" no no
else
  fail block-forward 'forward Visual Block surround did not complete'
fi

if setup_and_keys lem-yath-test-surround-block-reverse \
    block-reverse C-v k k l S ']'; then
  assert_result block-reverse block-reverse "$block_compact" yes no 5
else
  fail block-reverse 'reverse-corner Visual Block surround did not complete'
fi

block_spaced=$'aa( 11 )zz\nbb( 22 )yy\ncc( 33 )xx\n'
if setup_and_keys lem-yath-test-surround-block-forward \
    block-forward C-v j j l S '('; then
  assert_result block-spaced block-forward "$block_spaced" yes no 3
else
  fail block-spaced 'spaced Visual Block surround did not complete'
fi

block_short=$'aa[11]zz\nb\ncc[33]xx\n'
if setup_and_keys lem-yath-test-surround-block-short \
    block-short C-v j j l S ']'; then
  assert_result block-short-skip block-short "$block_short" yes no 3
else
  fail block-short-skip 'short row was not skipped'
fi

block_partial=$'aa[11]zz\nbb[2]\ncc[33]xx\n'
if setup_and_keys lem-yath-test-surround-block-partial \
    block-partial C-v j j l S ']'; then
  assert_result block-short-partial block-partial "$block_partial" yes no 3
else
  fail block-short-partial 'partially covered row was not surrounded to EOL'
fi

block_eol_left=$'a[a1]1zz\nb[]\nc[c3]3xx\n'
if setup_and_keys lem-yath-test-surround-block-eol-left \
    block-eol-left C-v j j l S ']'; then
  assert_result block-eol-at-left block-eol-left "$block_eol_left" yes no 2
else
  fail block-eol-at-left 'row ending at the left column was not surrounded'
fi

if setup_and_keys lem-yath-test-surround-block-protected \
    block-protected C-v j j l S ']'; then
  assert_result block-read-only-preflight block-protected "$block_source" no no
else
  fail block-read-only-preflight 'protected block boundary partially mutated'
fi

if setup_and_keys lem-yath-test-surround-tag-delete tag-delete d s t; then
  assert_result tag-delete tag-delete '<div>alpha</div>' yes yes
else
  fail tag-delete 'nested tag deletion did not complete'
fi

if invoke_setup lem-yath-test-surround-tag-change tag-change; then
  lem_keys "$session" c s t t
  tmux_cmd send-keys -t "$session" -l 'section'
  lem_keys "$session" Enter
  sleep 0.35
  record_result tag-change &&
    assert_result tag-change-preserve-attributes tag-change \
      '<section class="lead">alpha</section>' yes yes
else
  fail tag-change-preserve-attributes 'attribute-preserving tag change did not open'
fi

if invoke_setup lem-yath-test-surround-tag-change tag-change; then
  lem_keys "$session" c s '<' t
  tmux_cmd send-keys -t "$session" -l 'section>'
  sleep 0.35
  record_result tag-change &&
    assert_result tag-change-discard-attributes tag-change \
      '<section>alpha</section>' yes yes
  lem_keys "$session" u
  sleep 0.25
  record_result tag-change &&
    assert_result tag-change-one-undo tag-change \
      '<p class="lead">alpha</p>' no no
else
  fail tag-change-discard-attributes 'explicit tag change did not open'
fi

quoted_tag_source='<div data-value="x>y"><img src='"'"'z>q'"'"'/>alpha</div>'
quoted_tag_result='<img src='"'"'z>q'"'"'/>alpha'
if setup_and_keys lem-yath-test-surround-tag-quoted-attribute \
    tag-quoted-attribute d s t; then
  assert_result tag-quoted-attribute tag-quoted-attribute \
    "$quoted_tag_result" yes yes
else
  fail tag-quoted-attribute 'quoted attribute or self-closing tag confused matching'
fi

if setup_and_keys lem-yath-test-surround-tag-malformed tag-malformed d s t; then
  assert_result tag-malformed-fail-closed tag-malformed \
    '<div><span>alpha</div></span>' no yes
else
  fail tag-malformed-fail-closed 'malformed tag command did not return safely'
fi

if ((failed)); then
  printf '%s\n' '--- surround report ---'
  sed -n '1,240p' "$LEM_YATH_SURROUND_REPORT"
  exit 1
fi

printf 'All balanced-surround checks passed.\n'
