#!/usr/bin/env bash
# Real-TUI acceptance for generic PDF and EPUB reading inside Lem.
set -euo pipefail

export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tui-driver.sh
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-documents-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-documents.XXXXXX")"
session="lem-yath-documents-$id"

cleanup() {
  lem_stop "$session" || true
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_DOCUMENTS_REPORT="$root/report"
export LEM_YATH_DOCUMENTS_LOG="$root/argv.jsonl"
export LEM_YATH_DOCUMENTS_PDF="$root/reader payload;safe.PDF"
export LEM_YATH_DOCUMENTS_EPUB="$root/reader payload;safe.epub"
export LEM_YATH_DOCUMENTS_FIFO="$root/nonregular.pdf"
export LEM_YATH_DOCUMENTS_LARGE="$root/large.pdf"
export LEM_YATH_DOCUMENTS_OVERSIZED="$root/oversized.epub"
export LEM_YATH_DOCUMENTS_SLOW="$root/slow.epub"
fakebin="$root/fake bin;safe"
export LEM_YATH_DOCUMENTS_FAKE_BIN="$fakebin"

mkdir -p "$HOME" "$XDG_CACHE_HOME" "$fakebin"
: >"$LEM_YATH_DOCUMENTS_REPORT"
: >"$LEM_YATH_DOCUMENTS_LOG"
printf 'not decoded as PDF\n' >"$LEM_YATH_DOCUMENTS_PDF"
printf 'not decoded as EPUB\n' >"$LEM_YATH_DOCUMENTS_EPUB"
printf 'bounded output\n' >"$LEM_YATH_DOCUMENTS_OVERSIZED"
printf 'bounded time\n' >"$LEM_YATH_DOCUMENTS_SLOW"
mkfifo "$LEM_YATH_DOCUMENTS_FIFO"
truncate -s 536870913 "$LEM_YATH_DOCUMENTS_LARGE"

cp "$here/scripts/fake-documents-tool.py" "$fakebin/tool"
python="$(command -v python3)"
sed -i "1c#!$python" "$fakebin/tool"
chmod +x "$fakebin/tool"
for name in pdfinfo pdftotext pandoc xdg-open; do
  cp "$fakebin/tool" "$fakebin/$name"
done
real_pdfinfo="$(command -v pdfinfo)"
real_pdftotext="$(command -v pdftotext)"
real_pandoc="$(command -v pandoc)"
export PATH="$fakebin:$PATH"

source_file="$root/source file;safe.txt"
printf 'Document source remains exact\n' >"$source_file"

real_pdf="$root/real reader.pdf"
real_markdown="$root/real reader.md"
real_epub="$root/real reader.epub"
printf '# Real EPUB Chapter\n\nReal Pandoc body.\n' >"$real_markdown"
python3 - "$real_pdf" <<'PY'
import sys

path = sys.argv[1]
stream = b"BT /F1 18 Tf 72 720 Td (Real Poppler Page) Tj ET\n"
objects = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
    b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"endstream",
]
pdf = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
offsets = [0]
for number, body in enumerate(objects, 1):
    offsets.append(len(pdf))
    pdf.extend(f"{number} 0 obj\n".encode())
    pdf.extend(body)
    pdf.extend(b"\nendobj\n")
xref = len(pdf)
pdf.extend(f"xref\n0 {len(objects) + 1}\n".encode())
pdf.extend(b"0000000000 65535 f \n")
for offset in offsets[1:]:
    pdf.extend(f"{offset:010d} 00000 n \n".encode())
pdf.extend(
    f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
    f"startxref\n{xref}\n%%EOF\n".encode()
)
with open(path, "wb") as output:
    output.write(pdf)
PY

failed=0
pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  sed -n '1,160p' "$LEM_YATH_DOCUMENTS_REPORT" 2>/dev/null || true
  sed -n '1,120p' "$LEM_YATH_DOCUMENTS_LOG" 2>/dev/null || true
  sed -n '1,160p' "$XDG_CACHE_HOME/lem-yath/debug.log" 2>/dev/null || true
}

report_count() { grep -c "^$1" "$LEM_YATH_DOCUMENTS_REPORT" 2>/dev/null || true; }
wait_report() {
  local prefix=$1 before=$2 index=0
  while ((index < 120)); do
    if (( $(report_count "$prefix") > before )); then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}
latest() { grep "^$1" "$LEM_YATH_DOCUMENTS_REPORT" | tail -n 1; }
invoke_report() {
  local before
  before=$(report_count STATE)
  lem_keys "$session" F1
  wait_report STATE "$before"
}
invoke_refusal() {
  local key=$1 label=$2 before
  before=$(report_count REFUSED)
  lem_keys "$session" "$key"
  wait_report REFUSED "$before" && [[ $(latest REFUSED) == "REFUSED $label=yes source=yes" ]]
}
wait_log_count() {
  local expected=$1 index=0
  while ((index < 80)); do
    if [ "$(wc -l <"$LEM_YATH_DOCUMENTS_LOG")" -ge "$expected" ]; then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

if "$real_pdfinfo" "$real_pdf" | grep -Eq '^Pages:[[:space:]]+1$' &&
   "$real_pdftotext" -f 1 -l 1 -layout -nopgbrk -enc UTF-8 \
     "$real_pdf" - | grep -Fq 'Real Poppler Page' &&
   "$real_pandoc" "$real_markdown" --output="$real_epub" &&
   "$real_pandoc" --sandbox --from=epub --to=gfm --wrap=none \
     "$real_epub" | grep -Fq 'Real Pandoc body'; then
  pass real-tools 'pinned Poppler and Pandoc accepted the production argv and real files'
else
  fail real-tools 'a pinned document converter rejected a real PDF or EPUB fixture'
fi

fixture="$(lem-yath_lisp_string "$here/scripts/documents-fixture.lisp")"
lem_start "$session" "$source_file" --eval "(load #P$fixture)"

if wait_report READY 0 && lem_wait_for "$session" NORMAL 60 >/dev/null; then
  pass boot 'configured Lem loaded the isolated document fixture'
else
  fail boot 'configured Lem did not load the document fixture'
fi

lem_keys "$session" F3
if lem_wait_for "$session" 'Extracted PDF page 1' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE kind=PDF mode=pdf page=1 pages=3 chapter=none readonly=yes safe=yes unvisited=yes recent=yes keys=yes revert=yes count=1 source=yes' ]]; then
  pass pdf-open 'mixed-case PDF opened as bounded page text without binary decoding'
else
  fail pdf-open 'PDF dispatch, metadata, sanitization, or reader state diverged'
fi

lem_keys "$session" n
if lem_wait_for "$session" 'Extracted PDF page 2' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == *'page=2 pages=3 '* ]]; then
  pass pdf-next 'n rendered the next page and retained the page count'
else
  fail pdf-next 'PDF next-page navigation failed'
fi

lem_keys "$session" g
if lem_wait_for "$session" 'PDF page' 10 >/dev/null; then
  lem_keys "$session" C-a C-k
  tmux_cmd send-keys -t "$session" -l -- 3
  lem_keys "$session" Enter
fi
if lem_wait_for "$session" 'Extracted PDF page 3' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == *'page=3 pages=3 '* ]]; then
  pass pdf-goto 'g accepted an in-range page and rendered it'
else
  fail pdf-goto 'PDF page prompt or direct page rendering failed'
fi

before_open=$(wc -l <"$LEM_YATH_DOCUMENTS_LOG")
lem_keys "$session" o
if wait_log_count "$((before_open + 1))" &&
   python3 - "$LEM_YATH_DOCUMENTS_LOG" "$LEM_YATH_DOCUMENTS_PDF" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert calls[-1] == ["xdg-open", sys.argv[2]]
PY
then
  pass pdf-external 'o passed the exact PDF path to xdg-open without a shell'
else
  fail pdf-external 'PDF external fallback argv diverged'
fi

lem_keys "$session" F2 F3
if lem_wait_for "$session" 'Extracted PDF page 3' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == *'kind=PDF '*'count=1 '* ]]; then
  pass pdf-reuse 'reopening reused the live PDF buffer and its current page'
else
  fail pdf-reuse 'reopening duplicated or reset the PDF buffer'
fi

lem_keys "$session" F2 F4
if lem_wait_for "$session" 'First EPUB body' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE kind=EPUB mode=epub page=none pages=none chapter=none readonly=yes safe=yes unvisited=yes recent=yes keys=yes revert=yes count=2 source=yes' ]]; then
  pass epub-open 'EPUB opened as read-only Markdown with retained headings'
else
  fail epub-open 'EPUB conversion, mode, safety, or source preservation diverged'
fi

lem_keys "$session" n
if invoke_report && [[ $(latest STATE) == *'chapter=4  First Chapter '* ]]; then
  lem_keys "$session" n
fi
if invoke_report && [[ $(latest STATE) == *'chapter=8  Second Chapter '* ]]; then
  lem_keys "$session" p
fi
if invoke_report && [[ $(latest STATE) == *'chapter=4  First Chapter '* ]]; then
  pass epub-navigation 'n/p moved between converted EPUB chapter headings'
else
  fail epub-navigation 'EPUB chapter navigation or heading indexing failed'
fi

before_open=$(wc -l <"$LEM_YATH_DOCUMENTS_LOG")
lem_keys "$session" o
if wait_log_count "$((before_open + 1))" &&
   python3 - "$LEM_YATH_DOCUMENTS_LOG" "$LEM_YATH_DOCUMENTS_EPUB" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert calls[-1] == ["xdg-open", sys.argv[2]]
PY
then
  pass epub-external 'o passed the exact EPUB path to the desktop viewer'
else
  fail epub-external 'EPUB external fallback argv diverged'
fi

lem_keys "$session" F2
if invoke_refusal F6 fifo && invoke_refusal F7 large &&
   invoke_refusal F8 output && invoke_refusal F9 timeout; then
  pass refusal 'non-files, huge inputs, excessive output, and timeouts failed closed'
else
  fail refusal 'one bounded-input/process refusal did not recover on the source buffer'
fi

if python3 - "$LEM_YATH_DOCUMENTS_LOG" "$LEM_YATH_DOCUMENTS_PDF" "$LEM_YATH_DOCUMENTS_EPUB" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
pdf, epub = sys.argv[2:]
assert ["pdfinfo", pdf] in calls
for page in ("1", "2", "3"):
    assert ["pdftotext", "-f", page, "-l", page, "-layout", "-nopgbrk", "-enc", "UTF-8", pdf, "-"] in calls
assert ["pandoc", "--sandbox", "--from=epub", "--to=gfm", "--wrap=none", epub] in calls
assert all(isinstance(call, list) and all(isinstance(arg, str) for arg in call) for call in calls)
PY
then
  pass argv 'all document converters received exact inert argv vectors'
else
  fail argv 'converter selection or argument boundaries diverged'
fi

if [ ! -e "$root/PWNED" ] && [ ! -e "$PWD/PWNED" ]; then
  pass inert 'metacharacter filenames never crossed a shell boundary'
else
  fail inert 'a document filename escaped an argv boundary'
fi

if ((failed)); then exit 1; fi
printf 'SUMMARY PASS failures=0\n'
