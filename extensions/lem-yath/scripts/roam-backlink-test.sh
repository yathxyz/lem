#!/usr/bin/env bash
# Persistent Org-roam backlink panel through real ncurses Lem.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-roam-backlink-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-roam-backlink.XXXXXX")"
session="lem-yath-roam-backlink-$id"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_HOME="$root/lem-home/"
export WORKDIR="$root/work"
export LEM_YATH_ROAM_BACKLINK_REPORT="$root/report"
roam="$WORKDIR/roam"

cleanup() {
  lem_stop "$session" 2>/dev/null || true
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$LEM_HOME" "$roam"
: >"$LEM_YATH_ROAM_BACKLINK_REPORT"

cat >"$roam/target.org" <<'EOF'
:PROPERTIES:
:ID: target-id
:ROAM_ALIASES: "Target Alias"
:ROAM_REFS: @target-cite https://example.test/target https://example.test/a_(balanced)_path
:END:
#+title: Target Node

* Child Target
:PROPERTIES:
:ID: child-id
:END:
Child body
EOF

cat >"$roam/source.org" <<'EOF'
:PROPERTIES:
:ID: source-file-id
:END:
#+title: Alpha Source
Top [[id:target-id][first]]
Citation [cite:@target-cite]
Reference [[https://example.test/target][external]]
Balanced https://example.test/a_(balanced)_path
# [[id:target-id][comment decoy]]
#+begin_src text
[[id:target-id][block decoy]]
#+end_src
* Parent
** Source Heading
:PROPERTIES:
:ID: source-heading-id
:END:
Heading preview
[[id:target-id][second]]
*** Nested no ID
Nested [[id:child-id][child]]
* Sibling no ID
[[id:target-id][third]]
EOF

cat >"$roam/markdown.md" <<'EOF'
---
id: markdown-source-id
title: Markdown Source
---
Markdown [[Target Alias]]
Citation [@target-cite]
Reference [external](https://example.test/target)
Balanced [external](https://example.test/a_(balanced)_path)
EOF

fixture_lisp="$(lem-yath_lisp_string "$here/scripts/roam-backlink-fixture.lisp")"
failed=0

pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2" >&2
  lem_capture "$session" >&2 || true
}

mx() {
  local command=$1
  tmux_cmd send-keys -t "$session" Escape Escape M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.2
  tmux_cmd send-keys -t "$session" Enter
  sleep 0.3
}

report_has() {
  grep -qE "$1" "$LEM_YATH_ROAM_BACKLINK_REPORT"
}

wait_panel_occurrences() {
  local expected=$1 index=0 latest
  while ((index < 80)); do
    tmux_cmd send-keys -t "$session" F5
    sleep 0.25
    latest="$(grep '^PANEL ' "$LEM_YATH_ROAM_BACKLINK_REPORT" | tail -n 1)"
    if [[ "$latest" =~ target=target-id[[:space:]]occurrences=${expected}[[:space:]]reflinks=[0-9]+$ ]]; then
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

lem_start "$session" --eval "(load #P$fixture_lisp)" "$roam/target.org"
if ! lem_wait_for "$session" 'Target Node' 40 >/dev/null; then
  fail startup 'target note did not open'
  exit 1
fi
tmux_cmd send-keys -t "$session" Escape
sleep 0.5

if report_has '^STATIC target=4 child=1 reflinks=6 owners=source-file-id,source-file-id,markdown-source-id,source-heading-id ref-owners=source-file-id,source-file-id,source-file-id,markdown-source-id,markdown-source-id,markdown-source-id child-owner=source-heading-id no-buffers=yes$' &&
   report_has '^STATIC-DETAIL heading-outline=\("Parent" "Source Heading"\) heading-preview=yes decoy=no alias=yes$'; then
  pass snapshot 'backlinks and citation/URL reflinks resolve with source ownership and previews'
else
  fail snapshot 'bounded snapshot parsing or ownership differed'
fi

mx org-roam-buffer-toggle
if lem_wait_for "$session" 'Backlinks:' 20 >/dev/null; then
  tmux_cmd send-keys -t "$session" F5
  sleep 0.4
  if report_has '^PANEL live=yes visible=yes width=[0-9]+ display=[0-9]+ target=target-id occurrences=4 reflinks=6$'; then
    pass panel 'M-x toggle opened the persistent 0.4-width right-side panel'
  else
    fail panel 'right-side visibility, target, or occurrence count differed'
  fi
else
  fail panel 'asynchronous backlink panel did not render'
fi

tmux_cmd send-keys -t "$session" F3
sleep 0.4
tmux_cmd send-keys -t "$session" Enter
sleep 0.7
tmux_cmd send-keys -t "$session" F9
sleep 0.4
if report_has '^ORIGIN file=source.org line=6 column=9 text="Citation \[cite:@target-cite\]"$'; then
  pass reflink-visit 'Return opened the exact citation represented by a reflink row'
else
  fail reflink-visit 'Return did not preserve the exact reflink source position'
fi
tmux_cmd send-keys -t "$session" F7
sleep 0.5
lem_wait_for "$session" 'Backlinks:' 10 >/dev/null || true

tmux_cmd send-keys -t "$session" F6
sleep 0.5
if lem_wait_for "$session" 'Child Target' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" F5
  sleep 0.4
  if report_has '^PANEL .* target=child-id occurrences=1 reflinks=0$'; then
    pass node-switch 'post-command redisplay followed the nearest ID-bearing child node'
  else
    fail node-switch 'panel did not switch to the child node snapshot'
  fi
else
  fail node-switch 'child-node title was not rendered'
fi

tmux_cmd send-keys -t "$session" F7
sleep 0.5
lem_wait_for "$session" 'Backlinks:' 10 >/dev/null || true
tmux_cmd send-keys -t "$session" F8
sleep 0.4
tmux_cmd send-keys -t "$session" Enter
sleep 0.7
tmux_cmd send-keys -t "$session" F9
sleep 0.4
if report_has '^ORIGIN file=source.org line=5 column=4 text="Top \[\[id:target-id\]\[first\]\]"$'; then
  pass visit 'Return opened the exact source occurrence in the main window'
else
  fail visit 'Return did not preserve exact source line and column'
fi

tmux_cmd send-keys -t "$session" F7
sleep 0.5
lem_wait_for "$session" 'Backlinks:' 10 >/dev/null || true
tmux_cmd send-keys -t "$session" F8
sleep 0.4
sed -i 's/\[\[id:target-id\]\[first\]\]/[[id:child-id][first]]/' "$roam/source.org"
tmux_cmd send-keys -t "$session" Enter
if lem_wait_for "$session" 'changed on disk' 10 >/dev/null; then
  pass stale-refusal 'a stale snapshot refused to visit a shifted link'
else
  fail stale-refusal 'stale source mutation was not diagnosed'
fi

tmux_cmd send-keys -t "$session" g
if wait_panel_occurrences 3; then
  pass refresh 'g rebuilt the snapshot and removed the changed backlink'
else
  fail refresh 'refreshed occurrence count remained stale'
fi

tmux_cmd send-keys -t "$session" F4
tmux_cmd send-keys -t "$session" F7
if wait_panel_occurrences 2; then
  pass save-refresh 'saving a visible roam note refreshed the panel without g'
else
  fail save-refresh 'the visible panel did not refresh after a roam note save'
fi

tmux_cmd send-keys -t "$session" F10
sleep 0.4
if report_has '^FOREIGN retained=yes$' &&
   report_has '^FOREIGN-REOPEN visible=yes$' &&
   lem_wait_for "$session" 'Backlinks:' 20 >/dev/null; then
  pass ownership 'closing an obscured panel left another subsystem side window intact'
else
  fail ownership 'panel cleanup deleted or replaced a foreign side window'
fi

tmux_cmd send-keys -t "$session" F8
sleep 0.4
tmux_cmd send-keys -t "$session" q
sleep 0.5
tmux_cmd send-keys -t "$session" F11
sleep 0.4
if report_has '^CLOSED side=no panel-visible=no$'; then
  pass close 'q closed only the backlink side window and retained its buffer snapshot'
else
  fail close 'q left the backlink side window visible'
fi

if lem_wait_for "$session" 'Backlinks:' 20 >/dev/null; then
  tmux_cmd send-keys -t "$session" F12
  sleep 0.5
fi
if report_has '^RELOAD side=no panel-live=no post-hook=no save-hook=no$'; then
  pass reload-cleanup 'reload cleanup removed the panel, worker generation, and hooks'
else
  fail reload-cleanup 'reload left panel or hook state behind'
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo 'Roam backlink tests passed.'
