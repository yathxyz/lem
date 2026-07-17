#!/usr/bin/env bash
# Hermetic regression tests for shared Org paths and capture placement.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-notes-$$}"
session="lem-yath-notes-$id"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-notes.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export PUBLIC_ORG_DIR="$root/public"
export LEM_YATH_NOTES_REPORT="$root/report"
export LEM_YATH_NOTES_ORIGIN="$WORKDIR/source.org"
mkdir -p "$HOME" "$WORKDIR" "$PUBLIC_ORG_DIR"
printf '%s\n' '# Source' 'alpha SELECTED omega' 'end' \
  >"$LEM_YATH_NOTES_ORIGIN"

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

test_file="$(lem-yath_lisp_string "$here/scripts/notes-test.lisp")"
lem_start_lem-yath_eval "$session" "(load #P$test_file)"
for _ in $(seq 1 240); do
  if [ -f "$LEM_YATH_NOTES_REPORT" ] &&
     grep -q '^READY ' "$LEM_YATH_NOTES_REPORT"; then
    break
  fi
  sleep 0.25
done

if [ ! -f "$LEM_YATH_NOTES_REPORT" ]; then
  echo "NOTES TEST FAILED: Lem produced no report"
  lem_capture "$session" 2>/dev/null || true
  exit 1
fi

cat "$LEM_YATH_NOTES_REPORT"
grep -q '^SUMMARY PASS ' "$LEM_YATH_NOTES_REPORT"
if ! grep -q '^READY ' "$LEM_YATH_NOTES_REPORT"; then
  echo "NOTES TEST FAILED: Lem did not reach interactive readiness" >&2
  lem_capture "$session" 2>/dev/null || true
  exit 1
fi

failed=0

pass() {
  printf 'PASS  %-30s %s\n' "$1" "$2"
}

fail() {
  printf 'FAIL  %-30s %s\n' "$1" "$2" >&2
  failed=1
}

report_count() {
  grep -cE "$1" "$LEM_YATH_NOTES_REPORT" 2>/dev/null || true
}

latest_report() {
  grep -E "$1" "$LEM_YATH_NOTES_REPORT" 2>/dev/null | tail -n 1 || true
}

report_is() {
  [ "$(latest_report "$1")" = "$2" ]
}

wait_report_count() {
  local pattern=$1 expected=$2 index=0 count
  while ((index < 80)); do
    count=$(report_count "$pattern")
    count=${count:-0}
    if ((count >= expected)); then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

record_key() {
  local key=$1 pattern=$2 before
  before=$(report_count "$pattern")
  lem_keys "$session" "$key"
  wait_report_count "$pattern" "$((before + 1))"
}

if record_key F5 '^ORIGIN '; then
  lem_keys "$session" Space o
  if lem_wait_for "$session" 'Org capture:.*\[i\] Inbox' 10 >/dev/null &&
     record_key F6 '^CAPTURE ' &&
     report_is '^CAPTURE ' \
       'CAPTURE request=yes session=no key=none current=source.org line=2 column=6 state=NORMAL mode=no title=no initial=no annotation=no origin-hook=1 capture-hook=0'; then
    pass capture-template-menu 'SPC o opened the one-key template selector at the exact origin'
  else
    fail capture-template-menu 'the one-key selector or pending request state diverged'
  fi
  lem_keys "$session" C-g
  if lem_wait_for "$session" 'Org capture cancelled' 10 >/dev/null &&
     record_key F6 '^CAPTURE ' &&
     report_is '^CAPTURE ' \
       'CAPTURE request=no session=no key=none current=source.org line=2 column=6 state=NORMAL mode=no title=no initial=no annotation=no origin-hook=0 capture-hook=0'; then
    pass capture-template-abort 'C-g removed the selector and restored the origin'
  else
    fail capture-template-abort 'template cancellation leaked state or moved the origin'
  fi
else
  fail capture-template-menu 'could not reset the capture origin'
fi

if record_key F9 '^OCCUPIED ' &&
   report_is '^OCCUPIED ' 'OCCUPIED live=yes sentinel=yes'; then
  lem_keys "$session" Space o
  lem_keys "$session" i
  if lem_wait_for "$session" 'capture buffer name is already in use' 10 >/dev/null &&
     record_key F6 '^CAPTURE ' &&
     report_is '^CAPTURE ' \
       'CAPTURE request=no session=no key=none current=source.org line=2 column=6 state=NORMAL mode=no title=no initial=no annotation=no origin-hook=0 capture-hook=0' &&
     record_key F9 '^OCCUPIED ' &&
     report_is '^OCCUPIED ' 'OCCUPIED live=no sentinel=no'; then
    pass capture-buffer-ownership 'an occupied private name failed closed without leaking capture state'
  else
    fail capture-buffer-ownership 'the collision erased user state or leaked a request/session'
  fi
else
  fail capture-buffer-ownership 'could not construct the occupied-name boundary'
fi

record_key F5 '^ORIGIN ' || fail capture-todo 'could not reset the TODO origin'
lem_keys "$session" Space o
lem_keys "$session" t
if lem_wait_for "$session" 'C-c C-c finalizes' 10 >/dev/null &&
   record_key F6 '^CAPTURE ' &&
   report_is '^CAPTURE ' \
     'CAPTURE request=no session=yes key=t current=*Org Capture* line=1 column=8 state=INSERT mode=yes title=no initial=no annotation=yes origin-hook=1 capture-hook=1'; then
  pass capture-template-render 'TODO template opened in Insert state at its %? position'
else
  fail capture-template-render 'TODO template layout, cursor, context, or hooks diverged'
fi

lem_keys "$session" -l 'Captured task'
record_key F6 '^CAPTURE ' || true
if [[ $(latest_report '^CAPTURE ') == *'session=yes key=t'*'title=yes'* ]]; then
  pass capture-edit 'the capture buffer accepted ordinary multiline Org editing'
else
  fail capture-edit 'typed capture text was not retained in the session buffer'
fi

lem_keys "$session" C-x C-s
if lem_wait_for "$session" 'Use C-c C-c to finalize' 10 >/dev/null &&
   record_key F7 '^TARGET ' &&
   [[ $(latest_report '^TARGET ') == *'todo=0'*'session=yes'*'capture-live=yes'* ]]; then
  pass capture-save-guard 'ordinary save neither finalized nor wrote the target'
else
  fail capture-save-guard 'C-x C-s bypassed or damaged the capture session'
fi

lem_keys "$session" C-c C-c
if lem_wait_for "$session" 'Captured to todo.org' 10 >/dev/null &&
   record_key F7 '^TARGET ' &&
   report_is '^TARGET ' \
     'TARGET todo=1 inbox=0 public=0 selected=0 annotation=1 id=0 request=no session=no capture-live=no current=source.org line=2 state=NORMAL'; then
  pass capture-finalize 'C-c C-c saved exact TODO metadata/context and restored Normal state'
else
  fail capture-finalize 'finalize did not save once or restore the exact origin'
fi

record_key F5 '^ORIGIN ' || fail capture-abort 'could not reset the abort origin'
lem_keys "$session" Space o
lem_keys "$session" i
lem_wait_for "$session" 'C-c C-c finalizes' 10 >/dev/null || true
lem_keys "$session" -l 'Aborted item'
lem_keys "$session" C-c C-k
if lem_wait_for "$session" 'Org capture aborted' 10 >/dev/null &&
   record_key F7 '^TARGET ' &&
   [[ $(latest_report '^TARGET ') == *'inbox=0'*'session=no'*'current=source.org line=2 state=NORMAL'* ]]; then
  pass capture-abort 'C-c C-k discarded the edit without touching its target'
else
  fail capture-abort 'abort wrote a target or failed to restore the origin'
fi

record_key F5 '^ORIGIN ' || fail capture-context 'could not reset the context origin'
lem_keys "$session" v e
lem_keys "$session" Space o
lem_keys "$session" p
if lem_wait_for "$session" 'C-c C-c finalizes' 10 >/dev/null &&
   record_key F6 '^CAPTURE ' &&
   [[ $(latest_report '^CAPTURE ') == *'session=yes key=p'*'initial=yes annotation=yes'* ]]; then
  pass capture-context 'Visual %i and local-file %a context reached the public template'
else
  fail capture-context 'the active region or source annotation was lost'
fi
lem_keys "$session" -l 'Public context'
lem_keys "$session" C-c C-c
if lem_wait_for "$session" 'Captured to inbox.org' 10 >/dev/null &&
   record_key F7 '^TARGET ' &&
   [[ $(latest_report '^TARGET ') == \
     'TARGET todo=1 inbox=0 public=1 selected=1 annotation=2 id=1 request=no session=no capture-live=no current=source.org line=2 state=VISUAL' ]]; then
  pass capture-public 'public capture kept UUID, selection, annotation, and Visual origin'
else
  fail capture-public 'public capture metadata/context or origin state diverged'
fi

record_key F5 '^ORIGIN ' || fail capture-reload 'could not reset the reload origin'
lem_keys "$session" Space o
lem_keys "$session" r
lem_wait_for "$session" 'C-c C-c finalizes' 10 >/dev/null || true
lem_keys "$session" -l 'Unfinished reload capture'
if record_key F8 '^RELOAD ' &&
   report_is '^RELOAD ' \
     'RELOAD request=no session=no capture-live=no current=source.org line=2 state=NORMAL origin-hook=0'; then
  pass capture-reload 'source reload aborted the transient session and removed its hooks'
else
  fail capture-reload 'reload left a buffer, session, hook, or displaced origin'
fi
lem_keys "$session" Space o
if lem_wait_for "$session" 'Org capture:.*\[i\] Inbox' 10 >/dev/null; then
  lem_keys "$session" C-g
  if lem_wait_for "$session" 'Org capture cancelled' 10 >/dev/null; then
    pass capture-reload-reopen 'the one-key capture selector remained usable after reload'
  else
    fail capture-reload-reopen 'post-reload selector could not cancel cleanly'
  fi
else
  fail capture-reload-reopen 'post-reload selector did not open'
fi

record_key F5 '^ORIGIN ' || fail daily-date 'could not reset the daily-note origin'
lem_keys "$session" Space n r d d
if lem_wait_for "$session" 'Find daily-note \[[0-9]{4}-[0-9]{2}-[0-9]{2}\]' 10 >/dev/null &&
   lem_wait_for "$session" 'S-arrows.*C-\.: today' 10 >/dev/null; then
  pass daily-calendar 'SPC n r d d opened the Org-style terminal calendar'
else
  fail daily-calendar 'the daily-note key path did not display its date calendar'
fi
lem_keys "$session" -l 'sep 15 2026'
sleep 0.8
lem_keys "$session" Enter
sleep 1
if record_key F10 '^DAILY ' &&
   report_is '^DAILY ' \
     'DAILY file=2026-09-15.org title=yes state=NORMAL prompt=no calendars=0 exists=no visited=yes parsed=2026-09-15'; then
  pass daily-date 'named-date input created the configured daily note and cleaned up the popup'
else
  fail daily-date 'daily named-date creation, state restoration, or popup cleanup diverged'
fi

record_key F5 '^ORIGIN ' || fail journal-entry 'could not reset the journal origin'
lem_keys "$session" Space n j j
if lem_wait_for "$session" 'TITLE: Sat, 2026-07-11' 10 >/dev/null &&
   record_key F11 '^JOURNAL ' &&
   report_is '^JOURNAL ' \
     'JOURNAL file=20260711.org title=1 entries=1 ready=yes line=3 column=7 state=NORMAL org=yes'; then
  pass journal-entry 'SPC n j j opened an exact text-ready configured entry'
else
  fail journal-entry 'the journal path, title, entry, point, state, or Org mode diverged'
fi

lem_keys "$session" Space n j j
if record_key F11 '^JOURNAL ' &&
   report_is '^JOURNAL ' \
     'JOURNAL file=20260711.org title=1 entries=2 ready=yes line=5 column=7 state=NORMAL org=yes'; then
  pass journal-reuse 'repeated SPC n j j reused the title and appended a ready entry'
else
  fail journal-reuse 'repeated journal entry creation duplicated or misplaced content'
fi

record_key F5 '^ORIGIN ' || fail journal-visual 'could not reset the Visual journal origin'
lem_keys "$session" v e
lem_keys "$session" Space n j j
if record_key F11 '^JOURNAL ' &&
   report_is '^JOURNAL ' \
     'JOURNAL file=20260711.org title=1 entries=3 ready=yes line=7 column=7 state=NORMAL org=yes'; then
  pass journal-visual 'Visual SPC n j j reached the same text-ready Normal destination'
else
  fail journal-visual 'Visual invocation retained selection state or misplaced the entry'
fi

if [ "$failed" -ne 0 ]; then
  tail -n 50 "$LEM_YATH_NOTES_REPORT" >&2 || true
  lem_capture "$session" >&2 || true
  exit 1
fi

printf 'Notes and Org capture tests passed.\n'
