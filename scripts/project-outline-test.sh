#!/usr/bin/env bash
# Directory-local consult-outline behavior in real ncurses Lem.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-project-outline-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-project-outline.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export LEM_YATH_COMPLETION_STATE_FILE="$root/completion-ranking.sexp"
export LEM_YATH_PROJECT_OUTLINE_REPORT="$root/report"
export LEM_YATH_PROJECT_OUTLINE_MAIN="$root/config/main.el"
export LEM_YATH_PROJECT_OUTLINE_EMPTY="$root/config/empty.el"
export LEM_YATH_PROJECT_OUTLINE_OUTSIDE="$root/outside/outside.el"
export LEM_YATH_PROJECT_OUTLINE_MALICIOUS="$root/malicious/malicious.el"
export LEM_YATH_PROJECT_OUTLINE_READER_MARKER="$root/reader-evaluated"
mkdir -p "$HOME" "$WORKDIR" "$root/config" "$root/outside" "$root/malicious"

session="lem-project-outline-$id"
fixture="$(lem-yath_lisp_string "$here/scripts/project-outline-fixture.lisp")"
init="$(lem-yath_lisp_string "$LEM_YATH_SOURCE/init.lisp")"
marker="$(lem-yath_lisp_string "$LEM_YATH_PROJECT_OUTLINE_READER_MARKER")"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  sed -n '1,220p' "$LEM_YATH_PROJECT_OUTLINE_REPORT" 2>/dev/null || true
}

report_count() {
  grep -cE "$1" "$LEM_YATH_PROJECT_OUTLINE_REPORT" 2>/dev/null || true
}

wait_report_count() {
  local pattern=$1 expected=$2 i
  for i in $(seq 1 100); do
    [ "$(report_count "$pattern")" -ge "$expected" ] && return 0
    sleep 0.1
  done
  return 1
}

send_chord() {
  tmux_cmd send-keys -t "$session" "$@"
}

invoke_mx() {
  local command=$1 prompt=${2:-}
  send_chord Escape
  sleep 0.15
  send_chord Escape
  sleep 0.15
  send_chord M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.4
  send_chord Enter
  if [ -n "$prompt" ]; then
    lem_wait_for "$session" "$prompt" 10 >/dev/null
  fi
}

printf '%s\n' \
  "((emacs-lisp-mode . ((eval . (local-set-key (kbd \"C-c i\") #'consult-outline))" \
  '                       (outline-regexp . ";;;"))))' \
  >"$root/config/.dir-locals.el"

for line in $(seq 1 80); do
  case "$line" in
    3) printf '%s\n' ';;; Alpha section' ;;
    20) printf '%s\n' ';;;; Nested-looking section' ;;
    40) printf '%s\n' ';;; Second target section' ;;
    55) printf '%s\n' ';; Not an outline heading' ;;
    60) printf '%s\n' ';;; Final section' ;;
    *) printf '(defparameter *outline-line-%d* %d)\n' "$line" "$line" ;;
  esac
done >"$LEM_YATH_PROJECT_OUTLINE_MAIN"

printf '%s\n' '(defparameter *empty-outline-file* t)' \
  >"$LEM_YATH_PROJECT_OUTLINE_EMPTY"
printf '%s\n' ';;; Outside heading sentinel' '(defparameter *outside* t)' \
  >"$LEM_YATH_PROJECT_OUTLINE_OUTSIDE"
printf '%s\n' ';;; Malicious heading sentinel' '(defparameter *malicious* t)' \
  >"$LEM_YATH_PROJECT_OUTLINE_MALICIOUS"
printf '%s\n' \
  "#.(progn (with-open-file (stream #P$marker :direction :output :if-exists :supersede :if-does-not-exist :create) (write-line \"executed\" stream)) '((emacs-lisp-mode . ((eval . (local-set-key (kbd \"C-c i\") #'consult-outline)) (outline-regexp . \";;;\"))))))" \
  >"$root/malicious/.dir-locals.el"
: >"$LEM_YATH_PROJECT_OUTLINE_REPORT"

lem_start "$session" \
  -q \
  --eval "(progn (load #P$init) (load #P$fixture))" \
  "$LEM_YATH_PROJECT_OUTLINE_MAIN"
if ! lem_wait_for "$session" 'Alpha section' 30 >/dev/null ||
   ! wait_report_count '^READY$' 1; then
  fail startup 'the configured Emacs Lisp fixture did not open'
  exit 1
fi

if grep -q '^JUMP-CONFIG delay=30 stages=4 colors=#ff0000,#b90019,#71001a,#350717$' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass jump-config 'the production delay, iteration count, and TTY fade match Pulsar'
else
  fail jump-config 'the configured Pulsar timing or Modus fade palette differed'
fi

send_chord C-c z r
wait_report_count '^STATE file=main ' 1 || true
activation="$(grep '^STATE file=main ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
if grep -q 'minor=yes regexp=";;;" normal=LEM-YATH-CONSULT-OUTLINE emacs=LEM-YATH-CONSULT-OUTLINE insert=LEM-YATH-LLM-SEND visual=LEM-YATH-LLM-SEND' <<<"$activation"; then
  pass activation 'the exact dir-local scope preserves normal/Emacs versus Insert/Visual precedence'
else
  fail activation 'mode activation or C-c i state precedence differed'
  exit 1
fi

send_chord C-c z c
wait_report_count '^CANDIDATES count=4$' 1 || true
candidates_ok=1
grep -q '^CANDIDATE line=3 label=";;; Alpha section"$' "$LEM_YATH_PROJECT_OUTLINE_REPORT" || candidates_ok=0
grep -q '^CANDIDATE line=20 label=";;;; Nested-looking section"$' "$LEM_YATH_PROJECT_OUTLINE_REPORT" || candidates_ok=0
grep -q '^CANDIDATE line=40 label=";;; Second target section"$' "$LEM_YATH_PROJECT_OUTLINE_REPORT" || candidates_ok=0
grep -q '^CANDIDATE line=60 label=";;; Final section"$' "$LEM_YATH_PROJECT_OUTLINE_REPORT" || candidates_ok=0
if [ "$candidates_ok" = 1 ]; then
  pass candidates 'literal ;;; headings include longer prefixes and retain source order'
else
  fail candidates 'candidate collection differed from Consult outline-regexp behavior'
fi

send_chord C-c z b
send_chord C-c z r
wait_report_count '^STATE file=main line=80 ' 1 || true
origin="$(grep '^STATE file=main line=80 ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
origin_view="$(sed -n 's/^.* view=\([^ ]*\) minor=.*$/\1/p' <<<"$origin")"

send_chord C-c i
if lem_wait_for "$session" 'Go to heading:' 10 >/dev/null; then
  sleep 0.4
  screen="$(lem_capture "$session")"
  alpha_row="$(grep -n -m1 '3 ;;; Alpha section' <<<"$screen" | cut -d: -f1)"
  nested_row="$(grep -n -m1 '20 ;;;; Nested-looking section' <<<"$screen" | cut -d: -f1)"
  second_row="$(grep -n -m1 '40 ;;; Second target section' <<<"$screen" | cut -d: -f1)"
  final_row="$(grep -n -m1 '60 ;;; Final section' <<<"$screen" | cut -d: -f1)"
  if [ -n "$alpha_row" ] && [ -n "$nested_row" ] &&
     [ -n "$second_row" ] && [ -n "$final_row" ] &&
     [ "$alpha_row" -lt "$nested_row" ] &&
     [ "$nested_row" -lt "$second_row" ] &&
     [ "$second_row" -lt "$final_row" ]; then
    pass presentation 'line-numbered candidates are visibly source ordered'
  else
    fail presentation 'the visible candidate order or line annotations differed'
  fi

  send_chord -l 'Second'
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=main line=40 column=4 ' 1 || true
  preview="$(grep '^STATE file=main line=40 column=4 ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  preview_view="$(sed -n 's/^.* view=\([^ ]*\) minor=.*$/\1/p' <<<"$preview")"
  if grep -q 'preview=";;; Second target section" input="Second"' <<<"$preview" &&
     grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0' <<<"$preview" &&
     [ -n "$origin_view" ] && [ -n "$preview_view" ] &&
     [ "$origin_view" != "$preview_view" ]; then
    pass preview 'filter focus moves to the literal match and recenters the source window'
  else
    fail preview 'focus preview did not move, place, or recenter as Consult does'
  fi

  send_chord C-g
  sleep 0.4
  send_chord C-c z r
  wait_report_count '^STATE file=main line=80 ' 2 || true
  restored="$(grep '^STATE file=main line=80 ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  restored_view="$(sed -n 's/^.* view=\([^ ]*\) minor=.*$/\1/p' <<<"$restored")"
  if [ "$restored_view" = "$origin_view" ] &&
     grep -q 'preview=NIL input=NIL pulse=no pulse-stage=none .*pulse-overlays=0' \
       <<<"$restored"; then
    pass cancel 'C-g restores exact source point and viewport'
  else
    fail cancel 'prompt cancellation leaked its preview point or viewport'
  fi
else
  fail presentation 'C-c i did not open the outline prompt'
fi

send_chord C-c i
if lem_wait_for "$session" 'Go to heading:' 10 >/dev/null; then
  send_chord -l 'Second'
  sleep 0.4
  send_chord Enter
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=main line=40 column=4 ' 2 || true
  final="$(grep '^STATE file=main line=40 column=4 ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  if grep -q 'pulse=yes pulse-stage=[0-3] pulse-line=40 pulse-attribute=LEM-YATH-JUMP-PULSE-[1-4]-ATTRIBUTE pulse-overlays=1' \
       <<<"$final"; then
    pass jump-pulse 'accepted outline navigation recenters and pulses only its destination line'
  else
    fail jump-pulse "accepted outline navigation lacked live Pulsar feedback: $final"
  fi
  send_chord C-o
  sleep 0.3
  send_chord C-c z r
  wait_report_count '^STATE file=main line=80 ' 3 || true
  if grep -q 'preview=NIL input=NIL' <<<"$final" &&
     [ "$(grep -c '^STATE file=main line=80 ' "$LEM_YATH_PROJECT_OUTLINE_REPORT")" -ge 3 ]; then
    pass final-jump 'one Return commits the match-position jump and C-o returns to origin'
  else
    fail final-jump 'final selection or Vi jumplist behavior differed'
  fi

  sleep 0.8
  send_chord C-c z r
  wait_report_count '^STATE file=main line=80 ' 4 || true
  expired="$(grep '^STATE file=main line=80 ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  if grep -q 'pulse=no pulse-stage=none pulse-line=none pulse-attribute=none pulse-overlays=0' \
       <<<"$expired"; then
    pass jump-expiry 'the fourth fade removes its timer and overlay cleanly'
  else
    fail jump-expiry "jump feedback leaked after its configured fade: $expired"
  fi
else
  fail final-jump 'the second outline prompt did not open'
fi

# Generic M-x Imenu is deliberately a separate path from Consult outline:
# pinned Lisp definitions, no live preview or pulse, recenter on acceptance,
# and one Vi jumplist entry.
if invoke_mx imenu 'Index item:'; then
  if grep -Fq 'Variables' <<<"$(lem_capture "$session")"; then
    pass imenu-group 'M-x Imenu opens the pinned Variables submenu'
  else
    fail imenu-group 'the top-level Lisp Imenu Variables group was not visible'
  fi
  tmux_cmd send-keys -t "$session" -l Variables
  send_chord Enter
  sleep 0.4
  tmux_cmd send-keys -t "$session" -l 'outline-line-41'
  sleep 0.5
  if grep -Fq '*outline-line-41*' <<<"$(lem_capture "$session")"; then
    pass imenu-presentation 'the successive prompt exposes the selected group'
  else
    fail imenu-presentation 'the filtered Lisp Imenu candidate was not visible'
  fi
  send_chord Enter
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=main line=41 column=14 ' 1 || true
  imenu_final="$(grep '^STATE file=main line=41 column=14 ' \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  imenu_view="$(sed -n 's/^.* view=\([^ ]*\) minor=.*$/\1/p' \
    <<<"$imenu_final")"
  if grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0' \
       <<<"$imenu_final" &&
     [ -n "$origin_view" ] && [ -n "$imenu_view" ] &&
     [ "$origin_view" != "$imenu_view" ]; then
    pass imenu-jump 'Lisp Imenu lands on the name, recenters, and does not pulse'
  else
    fail imenu-jump "the accepted Lisp Imenu destination differed: $imenu_final"
  fi
  send_chord C-o
  sleep 0.3
  send_chord C-c z r
  wait_report_count '^STATE file=main line=80 ' 5 || true
  if [ "$(grep -c '^STATE file=main line=80 ' \
          "$LEM_YATH_PROJECT_OUTLINE_REPORT")" -ge 5 ]; then
    pass imenu-jumplist 'C-o returns from generic Imenu to the exact origin'
  else
    fail imenu-jumplist 'generic Imenu did not record one Vi jump'
  fi
else
  fail imenu-command 'M-x imenu did not open the Index item prompt'
fi

send_chord C-c z 2
lem_wait_for "$session" 'Outside heading sentinel' 10 >/dev/null || true
send_chord C-c z r
wait_report_count '^STATE file=outside ' 1 || true
outside="$(grep '^STATE file=outside ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
if grep -q 'minor=no regexp=NIL normal=UNDEFINED-KEY .*insert=LEM-YATH-LLM-SEND visual=LEM-YATH-LLM-SEND' <<<"$outside"; then
  pass outside-scope 'the same major mode outside the declared tree does not steal C-c i'
else
  fail outside-scope 'the directory-local binding escaped its source tree'
fi

send_chord C-c z 3
lem_wait_for "$session" 'Malicious heading sentinel' 10 >/dev/null || true
send_chord C-c z r
wait_report_count '^STATE file=malicious ' 1 || true
malicious="$(grep '^STATE file=malicious ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
if grep -q 'minor=no regexp=NIL .*reader-marker=no$' <<<"$malicious" &&
   [ ! -e "$LEM_YATH_PROJECT_OUTLINE_READER_MARKER" ]; then
  pass reader-safety 'read-time evaluation is rejected before activation or side effects'
else
  fail reader-safety 'directory-local data was executed or accepted unsafely'
fi

send_chord C-c z 4
lem_wait_for "$session" 'empty-outline-file' 10 >/dev/null || true
send_chord C-c z r
wait_report_count '^STATE file=empty ' 1 || true
empty="$(grep '^STATE file=empty ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
send_chord C-c i
if grep -q 'minor=yes regexp=";;;" normal=LEM-YATH-CONSULT-OUTLINE' <<<"$empty" &&
   lem_wait_for "$session" 'No headings' 10 >/dev/null &&
   ! grep -q 'Go to heading:' <<<"$(lem_capture "$session")"; then
  pass empty 'a declared file with no headings fails before opening a prompt'
else
  fail empty 'the empty outline path did not fail closed'
fi

if [ "$failed" = 0 ]; then
  printf 'All project outline checks passed.\n'
else
  exit 1
fi
