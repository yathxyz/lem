#!/usr/bin/env bash
# Hermetic parser and real-ncurses coverage for metadata-aware roam nodes.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-roam-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-roam.XXXXXX")"
case "$root" in
  "" | /)
    echo "Refusing unsafe roam test directory: $root" >&2
    exit 1
    ;;
esac

session="lem-yath-roam-$id"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_HOME="$root/lem-home/"
export WORKDIR="$root/work"
export LEM_YATH_COMPLETION_STATE_FILE="$root/completion-ranking.sexp"
export LEM_YATH_ROAM_REPORT="$root/report"
export LEM_YATH_ROAM_ORIGIN="$WORKDIR/origin.org"
export LEM_YATH_ROAM_MARKDOWN_ORIGIN="$WORKDIR/origin.md"
export LEM_YATH_ROAM_TEXT_ORIGIN="$WORKDIR/origin.txt"
export LEM_YATH_ROAM_RACE_OUTSIDE="$root/outside-race"
roam="$WORKDIR/roam"

cleanup() {
  lem_stop "$session" || true
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$LEM_HOME" "$roam/sub" \
  "$roam/race-parent" "$root/outside" "$LEM_YATH_ROAM_RACE_OUTSIDE"
: >"$LEM_YATH_ROAM_REPORT"

printf '%s\n' '* Origin' 'ORIGIN-END' >"$LEM_YATH_ROAM_ORIGIN"
printf '%s\n' '# Markdown Origin' 'MARKDOWN-END' \
  >"$LEM_YATH_ROAM_MARKDOWN_ORIGIN"
printf '%s\n' 'Text Origin' 'TEXT-END' >"$LEM_YATH_ROAM_TEXT_ORIGIN"

printf '%s\n' \
  ':PROPERTIES:' \
  ':ID: file-id' \
  ':ROAM_ALIASES: "File Alias" bare\ alias' \
  ':END:' \
  '#+TITLE: File Node' \
  '#+FILETAGS: :filetag:shared:' \
  '#+BEGIN_SRC text' \
  '* Decoy Heading' \
  ':PROPERTIES:' \
  ':ID: block-decoy' \
  ':END:' \
  '#+END_SRC' \
  '* Parent :ancestor:' \
  '** TODO [#A] COMMENT Heading Node :local:' \
  'SCHEDULED: <2026-07-13 Mon>' \
  ':PROPERTIES:' \
  ':ID: heading-id' \
  ':ROAM_ALIASES: "Heading Alias" mixed' \
  ':END:' \
  'HEADING TARGET' \
  >"$roam/file-node.org"

printf '%s\n' \
  ':PROPERTIES:' \
  ':ID: duplicate-file' \
  ':END:' \
  '#+title: Duplicate Container' \
  '* Same Title' \
  ':PROPERTIES:' \
  ':ID: duplicate-a' \
  ':END:' \
  'DUPLICATE A TARGET' \
  '* Same Title' \
  ':PROPERTIES:' \
  ':ID: duplicate-b' \
  ':END:' \
  'DUPLICATE B TARGET' \
  >"$roam/sub/duplicates.org"

printf '\357\273\277---\r\nid: markdown-id\r\ntitle: Markdown Node\r\ntags: [#project, @deep-work]\r\nROAM_ALIASES: ["Mark Alias", MarkBare]\r\n---\r\nMARKDOWN TARGET\r\n' \
  >"$roam/markdown.md"

printf '%s\n' \
  '---' \
  'id: markdown-block-id' \
  'title: Block Markdown' \
  'tags: [#block-one, @block_two]' \
  'ROAM_ALIASES: [BlockAlias]' \
  '---' \
  'BLOCK MARKDOWN TARGET' \
  >"$roam/markdown-block.md"

printf '%s\n' \
  ':PROPERTIES:' \
  ':ID: unclosed-file' \
  ':END:' \
  '#+title: Unclosed Block File' \
  '#+begin_example' \
  '* False Node' \
  ':PROPERTIES:' \
  ':ID: block-decoy' \
  ':END:' \
  >"$roam/unclosed.org"

printf '%s\n' \
  ':PROPERTIES:' \
  ':ID: mutable-old' \
  ':ROAM_ALIASES: MutableAlias' \
  ':END:' \
  '#+title: Mutable Node' \
  'MUTABLE TARGET' \
  >"$roam/mutable.org"

printf '%s\n' \
  ':PROPERTIES:' ':ID: hidden-id' ':END:' '#+title: Hidden Node' \
  >"$roam/.hidden.org"
printf '%s\n' 'ignored.org' >"$roam/.gitignore"
printf '%s\n' \
  ':PROPERTIES:' ':ID: ignored-id' ':END:' '#+title: Ignored Node' \
  >"$roam/ignored.org"

printf '%s\n' 'inside probe' >"$roam/race-parent/probe.txt"
printf '%s\n' 'outside probe' >"$LEM_YATH_ROAM_RACE_OUTSIDE/probe.txt"

printf '%s\n' '#+title: No ID' >"$roam/no-id.org"
printf '%s\n' \
  '* Late Drawer' \
  '' \
  ':PROPERTIES:' \
  ':ID: late-drawer' \
  ':END:' \
  >"$roam/late-drawer.org"
printf '%s\n' \
  ':PROPERTIES:' ':ID: sync-conflict' ':END:' '#+title: Conflict' \
  >"$roam/ignored.sync-conflict-copy.org"
printf ':PROPERTIES:\n:ID: binary-id\n:END:\n#+title: Binary\0Tail\n' \
  >"$roam/binary.org"
printf ':PROPERTIES:\n:ID: invalid-id\n:END:\n#+title: Invalid\377\n' \
  >"$roam/invalid.org"
{
  printf '%s\n' ':PROPERTIES:' ':ID: oversized-id' ':END:' '#+title: Oversized'
  head -c 1048577 /dev/zero | tr '\0' x
} >"$roam/oversized.org"
mkfifo "$roam/not-a-note.org"
ln -s missing.org "$roam/dangling.org"
printf '%s\n' ':PROPERTIES:' ':ID: outside-id' ':END:' '#+title: Outside' \
  >"$root/outside/outside.org"
ln -s "$root/outside" "$roam/symlinked-directory"

BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-20}"
KEY_DELAY="${KEY_DELAY:-0.2}"
failed=0

pass() { printf 'PASS  %-30s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-30s %s\n' "$1" "$2" >&2
  lem_capture "$session" >&2 || true
}

report_count() {
  grep -cE "$1" "$LEM_YATH_ROAM_REPORT" 2>/dev/null || true
}

latest_report() {
  grep -E "$1" "$LEM_YATH_ROAM_REPORT" 2>/dev/null | tail -n 1 || true
}

report_is() {
  [ "$(latest_report "$1")" = "$2" ]
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
  local key
  for key in "$@"; do
    lem_keys "$session" "$key"
    sleep "$KEY_DELAY"
  done
}

record_key() {
  local key=$1 pattern=$2 before
  before=$(report_count "$pattern")
  lem_keys "$session" "$key"
  wait_report_count "$pattern" "$((before + 1))"
}

reset_origin() {
  record_key F5 '^ORIGIN-RESET '
}

reset_markdown_origin() {
  record_key F8 '^MARKDOWN-RESET '
}

reset_text_origin() {
  record_key F11 '^TEXT-RESET '
}

open_roam_prompt() {
  local action=$1
  lem_keys "$session" C-g
  sleep 0.2
  send_chord Space n r "$action"
  if [ "$action" = f ]; then
    lem_wait_for "$session" 'Roam node:' "$WAIT_TIMEOUT" >/dev/null
  else
    lem_wait_for "$session" 'Insert link to:' "$WAIT_TIMEOUT" >/dev/null
  fi
}

fixture="$(lem-yath_lisp_string "$here/scripts/roam-fixture.lisp")"
lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$LEM_YATH_ROAM_ORIGIN"

if wait_report_count '^READY boot=yes$' 1 "$BOOT_TIMEOUT" &&
   grep -q '^STATIC PASS failures=0$' "$LEM_YATH_ROAM_REPORT"; then
  pass bounded-node-index 'Org files/headings and Markdown front matter parsed safely'
else
  fail bounded-node-index 'static node-index assertions failed'
fi

if open_roam_prompt f; then
  screen=$(lem_capture "$session")
  if grep -Fq 'File Node' <<<"$screen" &&
     grep -Fq 'Heading Node' <<<"$screen" &&
     grep -Fq '#filetag' <<<"$screen" &&
     grep -Fq 'file-node.org' <<<"$screen" &&
     grep -Fq 'L14' <<<"$screen"; then
    pass picker-metadata 'SPC n r f displays file, title, and tag metadata'
  else
    fail picker-metadata 'initial node annotations were incomplete'
  fi
  lem_keys "$session" C-g
else
  fail picker-binding 'SPC n r f did not open the node prompt'
fi

reset_origin || fail origin-reset 'could not restore the origin buffer'
if open_roam_prompt f; then
  tmux_cmd send-keys -t "$session" -l 'mixed'
  if lem_wait_for "$session" 'Heading Node' "$WAIT_TIMEOUT" >/dev/null; then
    lem_keys "$session" Enter
    if lem_wait_for "$session" 'HEADING TARGET' "$WAIT_TIMEOUT" >/dev/null &&
       record_key F6 '^CURRENT ' &&
       report_is '^CURRENT ' 'CURRENT file=file-node.org line=14'; then
      pass heading-find 'metadata filtering opened the exact ID-bearing heading'
    else
      fail heading-find 'heading selection opened the wrong file position'
    fi
  else
    fail heading-filter 'alias filtering did not retain the heading node'
  fi
else
  fail heading-find 'could not open the find prompt'
fi

reset_origin || fail origin-reset-insert 'could not restore the insertion origin'
if open_roam_prompt i; then
  tmux_cmd send-keys -t "$session" -l 'mixed'
  lem_wait_for "$session" 'Heading Node' "$WAIT_TIMEOUT" >/dev/null || true
  lem_keys "$session" Enter
  if lem_wait_for "$session" '\[\[id:heading-id\]\[Heading Node\]\]' \
       "$WAIT_TIMEOUT" >/dev/null &&
     record_key F7 '^ORIGIN ' &&
     report_is '^ORIGIN ' 'ORIGIN link=yes count=1 modified=yes'; then
    pass org-id-insert 'SPC n r i inserted one metadata-titled ID link'
  else
    fail org-id-insert 'Org insertion did not produce the expected ID link'
  fi
  lem_keys "$session" u
  sleep 0.3
  if record_key F7 '^ORIGIN ' &&
     report_is '^ORIGIN ' 'ORIGIN link=no count=0 modified=no'; then
    pass org-id-insert-undo 'one normal-state undo removed the complete link'
  else
    fail org-id-insert-undo 'link insertion was not one clean undo step'
  fi
else
  fail org-id-insert 'could not open the insertion prompt'
fi

reset_markdown_origin ||
  fail markdown-origin-reset 'could not open the Markdown insertion origin'
if open_roam_prompt i; then
  tmux_cmd send-keys -t "$session" -l 'Mark Alias'
  if lem_wait_for "$session" 'Markdown Node' "$WAIT_TIMEOUT" >/dev/null; then
    lem_keys "$session" Enter
    if lem_wait_for "$session" '\[\[Markdown Node\]\]' \
         "$WAIT_TIMEOUT" >/dev/null &&
       record_key F9 '^MARKDOWN ' &&
       report_is '^MARKDOWN ' \
         'MARKDOWN link=yes count=1 modified=yes'; then
      pass markdown-wiki-insert 'Markdown insertion matched pinned md-roam [[Title]]'
    else
      fail markdown-wiki-insert 'Markdown insertion did not produce [[Title]]'
    fi
    lem_keys "$session" u
    sleep 0.3
    if record_key F9 '^MARKDOWN ' &&
       report_is '^MARKDOWN ' 'MARKDOWN link=no count=0 modified=no'; then
      pass markdown-wiki-insert-undo 'one undo removed the complete wiki link'
    else
      fail markdown-wiki-insert-undo 'wiki link insertion was not one undo step'
    fi
  else
    fail markdown-wiki-insert 'Markdown alias filtering produced no candidate'
  fi
else
  fail markdown-wiki-insert 'could not open the Markdown insertion prompt'
fi

reset_origin || fail origin-reset-global-id 'could not restore duplicate-ID origin'
if open_roam_prompt i; then
  tmux_cmd send-keys -t "$session" -l 'mixed'
  if lem_wait_for "$session" 'Heading Node' "$WAIT_TIMEOUT" >/dev/null; then
    printf '%s\n' \
      ':PROPERTIES:' ':ID: heading-id' ':END:' '#+title: Duplicate ID' \
      >"$roam/global-duplicate.org"
    lem_keys "$session" Enter
    if lem_wait_for "$session" 'globally ambiguous' "$WAIT_TIMEOUT" >/dev/null &&
       record_key F7 '^ORIGIN ' &&
       report_is '^ORIGIN ' 'ORIGIN link=no count=0 modified=no'; then
      pass global-id-refusal 'fresh global duplicate IDs refuse Org insertion'
    else
      fail global-id-refusal 'duplicate ID was inserted or changed the origin'
    fi
    rm -f -- "$roam/global-duplicate.org"
  else
    fail global-id-refusal 'could not select the duplicate-ID target'
  fi
else
  fail global-id-refusal 'could not open the duplicate-ID insertion prompt'
fi

reset_origin || fail origin-reset-duplicate 'could not restore duplicate test origin'
if open_roam_prompt f; then
  tmux_cmd send-keys -t "$session" -l 'Same'
  if lem_wait_for "$session" 'Same Title' "$WAIT_TIMEOUT" >/dev/null; then
    lem_keys "$session" Down
    sleep 0.2
    lem_keys "$session" Enter
    if lem_wait_for "$session" 'DUPLICATE B TARGET' "$WAIT_TIMEOUT" >/dev/null &&
       record_key F6 '^CURRENT ' &&
       report_is '^CURRENT ' 'CURRENT file=sub/duplicates.org line=10'; then
      pass duplicate-title-identity 'Down selected the second same-title node exactly'
    else
      fail duplicate-title-identity 'same-title selection collapsed node identity'
    fi
  else
    fail duplicate-title-identity 'duplicate candidates were not displayed'
  fi
else
  fail duplicate-title-identity 'could not open duplicate-node prompt'
fi

reset_origin || fail origin-reset-markdown 'could not restore Markdown test origin'
if open_roam_prompt f; then
  tmux_cmd send-keys -t "$session" -l 'project'
  if lem_wait_for "$session" 'Markdown Node' "$WAIT_TIMEOUT" >/dev/null; then
    lem_keys "$session" Enter
    if lem_wait_for "$session" 'MARKDOWN TARGET' "$WAIT_TIMEOUT" >/dev/null &&
       record_key F6 '^CURRENT ' &&
       report_is '^CURRENT ' 'CURRENT file=markdown.md line=1'; then
      pass markdown-find 'front-matter tags selected the exact Markdown node'
    else
      fail markdown-find 'Markdown node opened incorrectly'
    fi
  else
    fail markdown-filter 'Markdown tag filtering produced no candidate'
  fi
else
  fail markdown-find 'could not open Markdown-node prompt'
fi

reset_origin || fail origin-reset-stale 'could not restore stale-snapshot origin'
if open_roam_prompt f; then
  tmux_cmd send-keys -t "$session" -l 'MutableAlias'
  if lem_wait_for "$session" 'Mutable Node' "$WAIT_TIMEOUT" >/dev/null; then
    printf '%s\n' \
      ':PROPERTIES:' \
      ':ID: mutable-new' \
      ':ROAM_ALIASES: MutableAlias' \
      ':END:' \
      '#+title: Mutable Node' \
      'MUTABLE TARGET' \
      >"$roam/mutable.org"
    lem_keys "$session" Enter
    if lem_wait_for "$session" 'changed; reopen the picker' "$WAIT_TIMEOUT" \
         >/dev/null &&
       record_key F6 '^CURRENT ' &&
       report_is '^CURRENT ' 'CURRENT file=outside line=3'; then
      pass stale-snapshot 'same-size ID rewrite was refused without visiting a file'
    else
      fail stale-snapshot 'stale node identity was accepted or lost the origin'
    fi
  else
    fail stale-snapshot 'mutable node was not selectable'
  fi
else
  fail stale-snapshot 'could not open stale-snapshot prompt'
fi

if open_roam_prompt f; then
  tmux_cmd send-keys -t "$session" -l 'MutableAlias'
  lem_wait_for "$session" 'Mutable Node' "$WAIT_TIMEOUT" >/dev/null || true
  lem_keys "$session" Enter
  if lem_wait_for "$session" 'MUTABLE TARGET' "$WAIT_TIMEOUT" >/dev/null &&
     record_key F6 '^CURRENT ' &&
     report_is '^CURRENT ' 'CURRENT file=mutable.org line=1'; then
    pass fresh-snapshot 'reopening the picker observed the rewritten node ID'
  else
    fail fresh-snapshot 'fresh prompt retained stale node data'
  fi
else
  fail fresh-snapshot 'could not reopen the node prompt'
fi

reset_origin || fail origin-reset-abort 'could not restore abort test origin'
if open_roam_prompt f; then
  tmux_cmd send-keys -t "$session" -l 'qqq'
  if lem_wait_for "$session" 'Roam node: qqq' "$WAIT_TIMEOUT" >/dev/null; then
    screen=$(lem_capture "$session")
  else
    screen='File Node'
  fi
  if ! grep -Fq 'File Node' <<<"$screen" &&
     ! grep -Fq 'Heading Node' <<<"$screen"; then
    send_chord BSpace BSpace BSpace
  else
    fail no-match-setup 'qqq did not establish a zero-result picker state'
  fi
  if lem_wait_for "$session" 'File Node' "$WAIT_TIMEOUT" >/dev/null; then
    lem_keys "$session" C-g
    if record_key F6 '^CURRENT ' &&
       report_is '^CURRENT ' 'CURRENT file=outside line=3'; then
      pass no-match-recovery 'Backspace recovered candidates and C-g kept origin'
    else
      fail no-match-recovery 'abort changed the origin buffer or point'
    fi
  else
    fail no-match-recovery 'zero-result query did not recover'
  fi
else
  fail no-match-recovery 'could not open abort/recovery prompt'
fi

reset_origin || fail origin-reset-random 'could not restore random-node origin'
send_chord Space n r a
sleep 0.5
if record_key F6 '^CURRENT '; then
  current=$(latest_report '^CURRENT ')
  if [[ "$current" =~ ^CURRENT\ file=.+\.(org|md)\ line=[0-9]+$ ]] &&
     [[ "$current" != *'file=outside'* ]]; then
    pass random-binding 'SPC n r a opened one indexed node at its recorded line'
  else
    fail random-binding "random command did not visit an indexed node: $current"
  fi
else
  fail random-binding 'random command did not return control to the editor'
fi

reset_text_origin || fail text-origin-reset 'could not open the non-note origin'
if open_roam_prompt i; then
  tmux_cmd send-keys -t "$session" -l 'Mark Alias'
  lem_wait_for "$session" 'Markdown Node' "$WAIT_TIMEOUT" >/dev/null || true
  lem_keys "$session" Enter
  if lem_wait_for "$session" 'only be inserted in Org or Markdown files' \
       "$WAIT_TIMEOUT" >/dev/null &&
     record_key F6 '^CURRENT ' &&
     report_is '^CURRENT ' 'CURRENT file=outside line=3'; then
    pass non-note-insert-refusal 'scratch/text buffers refuse invented link syntax'
  else
    fail non-note-insert-refusal 'non-Org/Markdown insertion was accepted'
  fi
else
  fail non-note-insert-refusal 'could not open insertion from the text origin'
fi

if record_key F10 '^DIRTY ' &&
   report_is '^DIRTY ' 'DIRTY target=yes origin-line=3'; then
  if open_roam_prompt f; then
    tmux_cmd send-keys -t "$session" -l 'mixed'
    lem_wait_for "$session" 'Heading Node' "$WAIT_TIMEOUT" >/dev/null || true
    lem_keys "$session" Enter
    if lem_wait_for "$session" 'has unsaved changes' "$WAIT_TIMEOUT" >/dev/null &&
       record_key F6 '^CURRENT ' &&
       report_is '^CURRENT ' 'CURRENT file=outside line=3'; then
      pass dirty-target-refusal 'disk-derived node positions never enter a dirty buffer'
    else
      fail dirty-target-refusal 'dirty target was visited or origin state changed'
    fi
  else
    fail dirty-target-refusal 'could not open picker with a dirty target buffer'
  fi
else
  fail dirty-target-setup 'could not create the unsaved target-buffer state'
fi

if grep -q '^STATIC PASS failures=0$' "$LEM_YATH_ROAM_REPORT" &&
   ((failed == 0)); then
  printf '%s\n' 'Roam node tests passed.'
  exit 0
fi

printf '%s\n' '--- roam report ---' >&2
sed -n '1,260p' "$LEM_YATH_ROAM_REPORT" >&2 || true
exit 1
