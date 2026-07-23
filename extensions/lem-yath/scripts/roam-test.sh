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
export TZ=UTC
export LEM_YATH_COMPLETION_STATE_FILE="$root/completion-ranking.sexp"
export LEM_YATH_ROAM_REPORT="$root/report"
export LEM_YATH_ROAM_ORIGIN="$WORKDIR/origin.org"
export LEM_YATH_ROAM_MARKDOWN_ORIGIN="$WORKDIR/origin.md"
export LEM_YATH_ROAM_FOLLOW_ORIGIN="$WORKDIR/roam/follow-origin.md"
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
printf '%s\n' \
  '# Follow Origin' \
  'Title [[Markdown Node]]' \
  'Alias [[shown|Mark Alias]]' \
  'ID [[markdown-id]]' \
  'Missing [[Fresh Follow]]' \
  'Ambiguous [[Same Title]]' \
  'Escaped \[[File Node]]' \
  '```text' \
  'Fenced [[Block Markdown]]' \
  '```' \
  'FOLLOW-END' \
  >"$LEM_YATH_ROAM_FOLLOW_ORIGIN"
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

goto_follow_link() {
  record_key F12 '^FOLLOW-GOTO '
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

start_roam_capture() {
  local action=$1 title=$2 template=$3
  open_roam_prompt "$action" || return 1
  tmux_cmd send-keys -t "$session" -l "$title"
  lem_wait_for "$session" "${title}" "$WAIT_TIMEOUT" >/dev/null || return 1
  lem_keys "$session" Enter
  lem_wait_for "$session" 'Roam template:' "$WAIT_TIMEOUT" >/dev/null || return 1
  lem_keys "$session" "$template"
  lem_wait_for "$session" 'C-c C-c finalizes' "$WAIT_TIMEOUT" >/dev/null
}

invoke_save_buffer() {
  tmux_cmd send-keys -t "$session" C-x C-s
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
         'MARKDOWN link=yes count=1 modified=yes mode=no'; then
      pass markdown-wiki-insert 'Markdown insertion matched pinned md-roam [[Title]]'
    else
      fail markdown-wiki-insert 'Markdown insertion did not produce [[Title]]'
    fi
    lem_keys "$session" u
    sleep 0.3
  if record_key F9 '^MARKDOWN ' &&
       report_is '^MARKDOWN ' 'MARKDOWN link=no count=0 modified=no mode=no'; then
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

if goto_follow_link; then
  lem_keys "$session" C-c C-o
  if lem_wait_for "$session" 'MARKDOWN TARGET' "$WAIT_TIMEOUT" >/dev/null &&
     record_key F6 '^CURRENT ' &&
     report_is '^CURRENT ' 'CURRENT file=markdown.md line=1'; then
    pass markdown-wiki-follow-title 'C-c C-o followed a pinned title link'
  else
    fail markdown-wiki-follow-title 'title link did not visit its md-roam node'
  fi
else
  fail markdown-wiki-follow-title 'could not position on the title link'
fi

if goto_follow_link; then
  lem_keys "$session" C-c C-o
  if lem_wait_for "$session" 'MARKDOWN TARGET' "$WAIT_TIMEOUT" >/dev/null &&
     record_key F6 '^CURRENT ' &&
     report_is '^CURRENT ' 'CURRENT file=markdown.md line=1'; then
    pass markdown-wiki-follow-alias 'alias-first [[label|alias]] resolution matched md-roam'
  else
    fail markdown-wiki-follow-alias 'alias link did not resolve the unique node'
  fi
else
  fail markdown-wiki-follow-alias 'could not position on the alias link'
fi

if goto_follow_link; then
  # Evil normal state owns C-u, just as it does in the source Emacs setup.
  # Enter Lem's Emacs state before exercising md-roam's universal prefix.
  lem_keys "$session" C-z C-u C-c C-o
  if lem_wait_for "$session" 'MARKDOWN TARGET' "$WAIT_TIMEOUT" >/dev/null &&
     record_key F9 '^FOLLOW-STATE ' &&
     report_is '^FOLLOW-STATE ' \
       'FOLLOW-STATE current=markdown.md line=1 windows=2 mode=yes modified=no hook=1'; then
    pass markdown-wiki-follow-other-window 'ID fallback and the prefix opened another window'
  else
    fail markdown-wiki-follow-other-window 'ID or other-window semantics diverged'
  fi
  lem_keys "$session" C-x 1
else
  fail markdown-wiki-follow-other-window 'could not position on the ID link'
fi

if goto_follow_link; then
  lem_keys "$session" C-c C-o
  if lem_wait_for "$session" 'Roam template:' "$WAIT_TIMEOUT" >/dev/null &&
     record_key F4 '^REQUEST ' &&
     report_is '^REQUEST ' \
       'REQUEST active=yes title="Fresh Follow" insert=no' &&
     record_key F9 '^FOLLOW-STATE ' &&
     report_is '^FOLLOW-STATE ' \
       'FOLLOW-STATE current=follow-origin.md line=5 windows=1 mode=yes modified=no hook=1'; then
    pass markdown-wiki-follow-capture 'a missing target entered non-inserting roam capture'
  else
    fail markdown-wiki-follow-capture 'missing-target capture changed source or request state'
  fi
  lem_keys "$session" C-g
else
  fail markdown-wiki-follow-capture 'could not position on the missing link'
fi

if goto_follow_link; then
  lem_keys "$session" C-c C-o
  if lem_wait_for "$session" 'wiki target.*ambiguous' "$WAIT_TIMEOUT" >/dev/null &&
     record_key F9 '^FOLLOW-STATE ' &&
     report_is '^FOLLOW-STATE ' \
       'FOLLOW-STATE current=follow-origin.md line=6 windows=1 mode=yes modified=no hook=1'; then
    pass markdown-wiki-follow-ambiguous 'duplicate titles failed closed at the source link'
  else
    fail markdown-wiki-follow-ambiguous 'an ambiguous wiki target was visited or mutated'
  fi
else
  fail markdown-wiki-follow-ambiguous 'could not position on the ambiguous link'
fi

for label in fenced escaped; do
  if goto_follow_link; then
    lem_keys "$session" C-c C-o
    if lem_wait_for "$session" 'not at a Markdown wiki link' "$WAIT_TIMEOUT" >/dev/null; then
      pass "markdown-wiki-follow-$label" "$label wiki syntax remained inert"
    else
      fail "markdown-wiki-follow-$label" "$label wiki syntax was treated as a link"
    fi
  else
    fail "markdown-wiki-follow-$label" "could not position on the $label decoy"
  fi
done

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

reset_origin || fail capture-template-abort-origin 'could not restore template-menu origin'
if open_roam_prompt f; then
  tmux_cmd send-keys -t "$session" -l 'Pending Capture'
  if lem_wait_for "$session" 'Pending Capture' "$WAIT_TIMEOUT" >/dev/null; then
    lem_keys "$session" Enter
  fi
  if lem_wait_for "$session" 'Roam template:' "$WAIT_TIMEOUT" >/dev/null &&
     record_key F4 '^REQUEST ' &&
     report_is '^REQUEST ' \
       'REQUEST active=yes title="Pending Capture" insert=no'; then
    lem_keys "$session" C-g
    if lem_wait_for "$session" 'Roam capture cancelled' "$WAIT_TIMEOUT" >/dev/null &&
       record_key F4 '^REQUEST ' &&
       report_is '^REQUEST ' 'REQUEST active=no' &&
       record_key F6 '^CURRENT ' &&
       report_is '^CURRENT ' 'CURRENT file=outside line=3'; then
      pass capture-template-abort 'C-g cancelled the template menu at the exact origin'
    else
      fail capture-template-abort 'template-menu abort retained state or moved the origin'
    fi
  else
    fail capture-template-abort 'missing title did not create a pending request'
  fi
else
  fail capture-template-abort 'could not open a missing-title picker'
fi

abort_path="$roam/20260203040506-abort_concept.org"
reset_origin || fail capture-abort-origin 'could not restore capture origin'
if start_roam_capture f 'Abort Concept' c; then
  if record_key F1 '^CAPTURE ' &&
     report_is '^CAPTURE ' \
       'CAPTURE active=yes path=20260203040506-abort_concept.org id=capture-001 title="Abort Concept" saved=no'; then
    sleep 0.4
    screen=$(lem_capture "$session")
  else
    screen=''
  fi
  if grep -Fq 'filetags:  concept' <<<"$screen" &&
     grep -Fq '▿ Claim' <<<"$screen" &&
     grep -Fq '▿ Context' <<<"$screen" &&
     grep -Fq '▿ Links' <<<"$screen"; then
    pass capture-template-ui 'missing title opened the selected concept template at %?'
  else
    fail capture-template-ui 'concept capture layout or session identity was wrong'
  fi
  invoke_save_buffer || true
  if lem_wait_for "$session" 'Use C-c C-c to finalize' "$WAIT_TIMEOUT" >/dev/null &&
     [ ! -e "$abort_path" ]; then
    pass capture-save-guard 'ordinary save was refused before capture finalization'
  else
    fail capture-save-guard 'ordinary save bypassed capture finalization'
  fi
  send_chord C-c C-k
  sleep 0.4
  if [ ! -e "$abort_path" ] &&
     record_key F1 '^CAPTURE ' && report_is '^CAPTURE ' 'CAPTURE active=no' &&
     record_key F6 '^CURRENT ' &&
     report_is '^CURRENT ' 'CURRENT file=outside line=3'; then
    pass capture-abort 'C-c C-k removed the unsaved capture and restored origin'
  else
    fail capture-abort 'abort left a file, session, or changed origin'
  fi
else
  fail capture-template-ui 'missing-title find did not enter capture'
fi

concept_path="$roam/20260203040506-fresh_concept.org"
reset_origin || fail capture-find-origin 'could not restore find-capture origin'
if start_roam_capture f 'Fresh Concept' c; then
  tmux_cmd send-keys -t "$session" -l 'Captured claim'
  if lem_wait_for "$session" 'Captured claim' "$WAIT_TIMEOUT" >/dev/null; then
    send_chord C-c C-c
  fi
  if lem_wait_for "$session" 'Captured roam node:' "$WAIT_TIMEOUT" >/dev/null &&
     [ -f "$concept_path" ] &&
     grep -qF ':ID: capture-002' "$concept_path" &&
     grep -qF '#+title: Fresh Concept' "$concept_path" &&
     grep -qF '#+created: [2026-02-03 Tue 04:05]' "$concept_path" &&
     grep -qF '#+filetags: :concept:' "$concept_path" &&
     grep -qF 'Captured claim' "$concept_path" &&
     record_key F6 '^CURRENT ' &&
     report_is '^CURRENT ' \
       'CURRENT file=20260203040506-fresh_concept.org line=9' &&
     record_key F1 '^CAPTURE ' && report_is '^CAPTURE ' 'CAPTURE active=no'; then
    pass capture-find-finalize 'find capture saved exact metadata/body and stayed on the node'
  else
    fail capture-find-finalize 'find capture did not finalize as the configured node'
  fi
else
  fail capture-find-finalize 'concept capture could not be started'
fi

project_path="$roam/20260203040506-project-fresh_project.org"
reset_origin || fail capture-insert-origin 'could not restore insert-capture origin'
if start_roam_capture i 'Fresh Project' p; then
  tmux_cmd send-keys -t "$session" -l 'Ship outcome'
  if lem_wait_for "$session" 'Ship outcome' "$WAIT_TIMEOUT" >/dev/null; then
    send_chord C-c C-c
  fi
  if lem_wait_for "$session" '\[\[id:capture-003\]\[Fresh Project\]\]' \
       "$WAIT_TIMEOUT" >/dev/null &&
     [ -f "$project_path" ] &&
     grep -qF ':ID: capture-003' "$project_path" &&
     grep -qF '#+filetags: :project:' "$project_path" &&
     grep -qF '* Outcome' "$project_path" &&
     grep -qF 'Ship outcome' "$project_path" &&
     record_key F2 '^CREATED-ORG ' &&
     report_is '^CREATED-ORG ' 'CREATED-ORG link=yes count=1 modified=yes'; then
    pass capture-org-insert 'finalize returned to origin and inserted one ID link'
  else
    fail capture-org-insert 'deferred Org link or project file was incorrect'
  fi
  lem_keys "$session" u
  sleep 0.3
  if record_key F2 '^CREATED-ORG ' &&
     report_is '^CREATED-ORG ' 'CREATED-ORG link=no count=0 modified=no' &&
     [ -f "$project_path" ]; then
    pass capture-org-insert-undo 'one undo removed only the link and kept the note'
  else
    fail capture-org-insert-undo 'capture insertion was not one origin undo step'
  fi
else
  fail capture-org-insert 'project capture could not be started'
fi

markdown_capture_path="$roam/20260203040506-fresh_markdown.md"
reset_markdown_origin ||
  fail capture-markdown-origin 'could not restore Markdown capture origin'
if start_roam_capture i 'Fresh Markdown' m; then
  tmux_cmd send-keys -t "$session" -l 'Markdown capture body'
  if lem_wait_for "$session" 'Markdown capture body' "$WAIT_TIMEOUT" >/dev/null; then
    send_chord C-c C-c
  fi
  if lem_wait_for "$session" '\[\[Fresh Markdown\]\]' "$WAIT_TIMEOUT" >/dev/null &&
     [ -f "$markdown_capture_path" ] &&
     grep -qF 'id: capture-004' "$markdown_capture_path" &&
     grep -qF 'title: Fresh Markdown' "$markdown_capture_path" &&
     grep -qF 'created: "2026-02-03T04:05:06+0000"' \
       "$markdown_capture_path" &&
     grep -qF 'tags: []' "$markdown_capture_path" &&
     grep -qF 'Markdown capture body' "$markdown_capture_path" &&
     record_key F3 '^CREATED-MD ' &&
     report_is '^CREATED-MD ' 'CREATED-MD link=yes count=1 modified=yes'; then
    pass capture-markdown-insert 'Markdown template finalized with one title wiki link'
  else
    fail capture-markdown-insert 'Markdown capture file or deferred link was incorrect'
  fi
  lem_keys "$session" u
  sleep 0.3
  if record_key F3 '^CREATED-MD ' &&
     report_is '^CREATED-MD ' 'CREATED-MD link=no count=0 modified=no' &&
     [ -f "$markdown_capture_path" ]; then
    pass capture-markdown-undo 'one undo removed the wiki link and kept the note'
  else
    fail capture-markdown-undo 'Markdown capture insertion was not one undo step'
  fi
else
  fail capture-markdown-insert 'Markdown capture could not be started'
fi

collision_path="$roam/20260203040506-collision_node.org"
reset_origin || fail capture-collision-origin 'could not restore collision origin'
if start_roam_capture f 'Collision Node' n; then
  printf '%s\n' 'EXTERNAL COLLISION CONTENT' >"$collision_path"
  send_chord C-c C-c
  collision_refused=no
  if lem_wait_for "$session" 'target appeared on disk' "$WAIT_TIMEOUT" >/dev/null; then
    if record_key F1 '^CAPTURE ' &&
       report_is '^CAPTURE ' \
         'CAPTURE active=yes path=20260203040506-collision_node.org id=capture-005 title="Collision Node" saved=no' &&
       [ "$(cat "$collision_path")" = 'EXTERNAL COLLISION CONTENT' ]; then
      collision_refused=yes
    fi
  fi
  if [ "$collision_refused" = yes ]; then
    pass capture-collision-refusal 'finalize refused a newly appeared target without overwrite'
  else
    fail capture-collision-refusal 'capture overwrote or lost a colliding target'
  fi
  send_chord C-c C-k
  sleep 0.3
  if record_key F1 '^CAPTURE ' && report_is '^CAPTURE ' 'CAPTURE active=no' &&
     [ "$(cat "$collision_path")" = 'EXTERNAL COLLISION CONTENT' ]; then
    pass capture-collision-abort 'abort kept the external collision and cleared session state'
  else
    fail capture-collision-abort 'collision cleanup changed external data or retained a session'
  fi
else
  fail capture-collision-refusal 'collision capture could not be started'
fi

if grep -q '^STATIC PASS failures=0$' "$LEM_YATH_ROAM_REPORT" &&
   ((failed == 0)); then
  printf '%s\n' 'Roam node tests passed.'
  exit 0
fi

printf '%s\n' '--- roam report ---' >&2
sed -n '1,260p' "$LEM_YATH_ROAM_REPORT" >&2 || true
exit 1
