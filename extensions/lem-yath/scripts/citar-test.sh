#!/usr/bin/env bash
# Real-TUI acceptance for the configured Citar bibliography-open workflow.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tui-driver.sh
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-citar-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-citar.XXXXXX")"
session="lem-yath-citar-$id"

cleanup() {
  lem_stop "$session" || true
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_CITAR_REPORT="$root/report"
export LEM_YATH_CITAR_OPEN_LOG="$root/open.jsonl"
fakebin="$root/fake bin;safe"
export LEM_YATH_CITAR_FAKE_BIN="$fakebin"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$fakebin" \
  "$WORKDIR/librarium" "$WORKDIR/roam/references" "$HOME/library"
: >"$LEM_YATH_CITAR_REPORT"
: >"$LEM_YATH_CITAR_OPEN_LOG"
cp "$here/scripts/fake-citar-xdg-open.py" "$fakebin/xdg-open"
python=$(command -v python3)
sed -i "1c#!$python" "$fakebin/xdg-open"
chmod +x "$fakebin/xdg-open"
export PATH="$fakebin:$PATH"

source_file="$root/source file;safe.txt"
pdf_file="$root/paper file.pdf"
text_file="$root/plain file.txt"
outside_note="$root/outside.org"
note_file="$WORKDIR/roam/references/note.org"
printf 'Citar source remains exact\n' >"$source_file"
printf 'fake pdf\n' >"$pdf_file"
printf 'Ordinary linked file\n' >"$text_file"
printf 'Outside note must remain closed\n' >"$outside_note"
printf 'Configured citation note\n' >"$note_file"
ln -s "$outside_note" "$WORKDIR/roam/references/link.org"

printf '%s\n' \
  '@article{dup,' \
  '  author = {Node, Nora},' \
  '  title = {Node Preferred},' \
  '  year = {2020}' \
  '}' \
  '@article{escaped,' \
  '  author = "Quote, Quinn",' \
  '  title = "The \"Quoted\" Result",' \
  '  year = "2026"' \
  '}' \
  '@article{nested,' \
  '  author = {Brace, Bailey},' \
  '  title = {Nested {Group} Title},' \
  '  year = {2027}' \
  '}' \
  >"$WORKDIR/librarium/nodes.bib"

printf '%s\n' \
  '@article{dup,' \
  '  author = {Wrong, Wendy},' \
  '  title = {Zotero Must Not Win},' \
  '  year = {1999}' \
  '}' \
  '@article{pdf,' \
  '  author = {Paper, Paula},' \
  '  title = {External PDF},' \
  '  year = {2021},' \
  "  file = {:$pdf_file:application/pdf}," \
  '  url = {https://wrong.invalid/must-not-open}' \
  '}' \
  '@article{url,' \
  '  author = {Web, Will},' \
  '  title = {URL Target},' \
  '  year = {2022},' \
  '  url = {https://example.invalid/a?x=1&safe=touch%20PWNED}' \
  '}' \
  '@article{note,' \
  '  author = {Note, Nina},' \
  '  title = {Note Target},' \
  '  year = {2023}' \
  '}' \
  '@article{text,' \
  '  author = {Text, Terry},' \
  '  title = {Text Target},' \
  '  year = {2024},' \
  "  file = {file://$text_file}" \
  '}' \
  '@article{badurl,' \
  '  author = {Bad, Blake},' \
  '  title = {Invalid URL},' \
  '  year = {2025},' \
  '  url = {--help;touch PWNED}' \
  '}' \
  >"$WORKDIR/librarium/zotero.bib"

failed=0
pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  sed -n '1,140p' "$LEM_YATH_CITAR_REPORT" 2>/dev/null || true
  sed -n '1,100p' "$LEM_YATH_CITAR_OPEN_LOG" 2>/dev/null || true
}

report_count() { grep -c "^$1" "$LEM_YATH_CITAR_REPORT" 2>/dev/null || true; }
wait_report() {
  local prefix=$1 before=$2 index=0
  while ((index < 80)); do
    if (( $(report_count "$prefix") > before )); then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}
latest() { grep "^$1" "$LEM_YATH_CITAR_REPORT" | tail -n 1; }
invoke_report() {
  local before
  before=$(report_count STATE)
  lem_keys "$session" F4
  wait_report STATE "$before"
}
wait_lines() {
  local path=$1 expected=$2 index=0
  while ((index < 80)); do
    if [ "$(wc -l <"$path")" -ge "$expected" ]; then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}
open_entry() {
  lem_keys "$session" Space y o
  lem_wait_for "$session" 'Open citation:' 20 >/dev/null
  tmux_cmd send-keys -t "$session" -l -- "$1"
  lem_keys "$session" Enter
}
restore_source() {
  lem_keys "$session" F5
  lem_wait_for "$session" NORMAL 20 >/dev/null
}

fixture="$(lem-yath_lisp_string "$here/scripts/citar-fixture.lisp")"
lem_start "$session" "$source_file" --eval "(load #P$fixture)"

if wait_report READY 0 && lem_wait_for "$session" NORMAL 60 >/dev/null &&
   grep -Fqx -- "EXEC xdg-open=$fakebin/xdg-open" "$LEM_YATH_CITAR_REPORT" &&
   invoke_report && [[ $(latest STATE) == *'parser=yes safe=yes source-live=yes source-exact=yes' ]]; then
  pass boot 'configured Lem loaded ordered BibTeX sources and the isolated opener'
else
  fail boot 'fixture, parser, containment checks, or fake opener resolution diverged'
fi
if ((failed)); then exit 1; fi

open_entry 'dup: Node (2020) Node Preferred'
if lem_wait_for "$session" 'No file, url or note for dup' 20 >/dev/null &&
   [ ! -s "$LEM_YATH_CITAR_OPEN_LOG" ]; then
  pass precedence 'the earlier nodes bibliography won a duplicate key'
else
  fail precedence 'duplicate-key source order or no-resource behavior diverged'
fi

open_entry 'pdf: Paper (2021) External PDF'
if wait_lines "$LEM_YATH_CITAR_OPEN_LOG" 1 &&
   python3 - "$LEM_YATH_CITAR_OPEN_LOG" "$pdf_file" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert calls == [[sys.argv[2]]]
PY
then
  pass pdf 'Zotero file syntax chose the existing PDF before its URL'
else
  fail pdf 'PDF extraction, precedence, or exact desktop-open argv diverged'
fi

open_entry 'url: Web (2022) URL Target'
if wait_lines "$LEM_YATH_CITAR_OPEN_LOG" 2 &&
   python3 - "$LEM_YATH_CITAR_OPEN_LOG" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert calls[-1] == ["https://example.invalid/a?x=1&safe=touch%20PWNED"]
PY
then
  pass url 'HTTP(S) resources remained one exact inert browser argument'
else
  fail url 'URL validation or desktop-open argv shape diverged'
fi

open_entry 'text: Text (2024) Text Target'
if lem_wait_for "$session" 'Ordinary linked file' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == "STATE current=$text_file parser=yes safe=yes source-live=yes source-exact=yes" ]]; then
  pass file 'an ordinary file:// resource opened inside Lem'
else
  fail file 'ordinary linked-file routing or source preservation diverged'
fi
restore_source

open_entry 'note: Note (2023) Note Target'
if lem_wait_for "$session" 'Configured citation note' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == "STATE current=$note_file parser=yes safe=yes source-live=yes source-exact=yes" ]]; then
  pass note 'the configured in-root Org citation note opened inside Lem'
else
  fail note 'citation-note lookup, containment, or source preservation diverged'
fi
restore_source

before_bad=$(wc -l <"$LEM_YATH_CITAR_OPEN_LOG")
open_entry 'badurl: Bad (2025) Invalid URL'
if lem_wait_for "$session" 'No file, url or note for badurl' 20 >/dev/null &&
   [ "$(wc -l <"$LEM_YATH_CITAR_OPEN_LOG")" -eq "$before_bad" ] &&
   invoke_report && [[ $(latest STATE) == "STATE current=$source_file parser=yes safe=yes source-live=yes source-exact=yes" ]]; then
  pass refusal 'non-HTTP targets and out-of-root notes failed closed'
else
  fail refusal 'an invalid target launched or displaced the source buffer'
fi

if [ ! -e "$root/PWNED" ] && [ ! -e "$PWD/PWNED" ]; then
  pass inert 'metacharacter paths and URLs never crossed a shell boundary'
else
  fail inert 'test metacharacters escaped an argv boundary'
fi

if ((failed)); then exit 1; fi
printf 'SUMMARY PASS failures=0\n'
