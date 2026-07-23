#!/usr/bin/env bash
# Real-ncurses coverage for pinned Dirvish presentation in directory-mode.
set -uo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-dirvish-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-dirvish.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_DIRVISH_REPORT="$root/report"
export LEM_YATH_DIRVISH_ROOT="$root/files"
export LEM_YATH_DIRVISH_SOURCE="${LEM_YATH_DIRVISH_SOURCE:-${LEM_YATH_SOURCE:-$here/lem-yath}/src/dirvish.lisp}"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" \
  "$LEM_YATH_DIRVISH_ROOT/child" "$LEM_YATH_DIRVISH_ROOT/zz-crowded"
printf 'one\n' >"$LEM_YATH_DIRVISH_ROOT/child/one"
printf 'two\n' >"$LEM_YATH_DIRVISH_ROOT/child/two"
printf 'three\n' >"$LEM_YATH_DIRVISH_ROOT/child/three"
head -c 1536 /dev/zero >"$LEM_YATH_DIRVISH_ROOT/size.bin"
printf 'DIRVISH VISIT\n' >"$LEM_YATH_DIRVISH_ROOT/open.txt"
ln -s open.txt "$LEM_YATH_DIRVISH_ROOT/zz-symlink-open"
mkfifo "$LEM_YATH_DIRVISH_ROOT/special.fifo"
for index in $(seq 1 205); do
  : >"$LEM_YATH_DIRVISH_ROOT/zz-crowded/entry-$index"
done
mkdir -p "$root/archive-source"
printf 'Dirvish archive payload\n' >"$root/archive-source/zz-archive-member.txt"
bsdtar -a -cf "$LEM_YATH_DIRVISH_ROOT/preview-archive;safe.zip" \
  -C "$root/archive-source" zz-archive-member.txt
rm "$root/archive-source/zz-archive-member.txt"
rmdir "$root/archive-source"
printf '# Dirvish EPUB Chapter\n\nDirvish EPUB body.\n' \
  >"$LEM_YATH_DIRVISH_ROOT/zz-epub-source.md"
pandoc "$LEM_YATH_DIRVISH_ROOT/zz-epub-source.md" \
  --output="$LEM_YATH_DIRVISH_ROOT/preview-book.epub"
python3 - "$LEM_YATH_DIRVISH_ROOT/preview-paper.pdf" \
  "$LEM_YATH_DIRVISH_ROOT/preview-image.png" <<'PY'
import base64
import sys

pdf_path, png_path = sys.argv[1:]
stream = b"BT /F1 18 Tf 72 720 Td (Dirvish PDF Page) Tj ET\n"
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
with open(pdf_path, "wb") as output:
    output.write(pdf)

png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk"
    "/x8AAusB9Y9Z4QAAAABJRU5ErkJggg=="
)
with open(png_path, "wb") as output:
    output.write(png)
PY
truncate -s 134217729 "$LEM_YATH_DIRVISH_ROOT/zz-oversized.pdf"
: >"$LEM_YATH_DIRVISH_REPORT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-dirvish-$id"
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
  sed -n '1,160p' "$LEM_YATH_DIRVISH_REPORT" 2>/dev/null || true
  lem_capture "$session" 2>/dev/null || true
}

wait_report() {
  local pattern=$1 timeout=${2:-15} index=0
  while ((index < timeout * 4)); do
    if grep -qE "$pattern" "$LEM_YATH_DIRVISH_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/dirvish-fixture.lisp")"
lem_start "$session" --eval "(load #P$fixture)"

if lem_wait_for "$session" 'NORMAL' 60 >/dev/null &&
   wait_report '^READY$' 60; then
  tmux_cmd resize-window -t "$session" -x 100 -y 24
  sleep 0.5
  pass boot 'configured Lem opened a real directory-mode buffer'
else
  fail boot 'directory fixture did not become ready'
fi

if wait_report '^STATIC mode=DIRECTORY-MODE inserters=1 exact=yes bytes=..1\.5k count=.....3$'; then
  pass pinned-defaults 'hidden details and six-cell format match pinned Dirvish defaults'
else
  fail pinned-defaults 'configured inserters or exact size formatting differed'
fi

lem_keys "$session" F2
if wait_report '^DISPLAY width=100 file-cells=100 file-tail=..1\.5k file-size=..1\.5k file-source=..size\.bin directory-cells=100 directory-tail=.....3 directory-size=.....3 directory-source=..child/ modified=no readonly=yes$'; then
  pass display-100 'names stay compact while size and child count align at column 100'
else
  fail display-100 '100-column logical display or source text differed'
fi

screen="$(lem_capture "$session")"
if [[ "$screen" == *'size.bin'*'1.5k'* ]] &&
   [[ "$screen" == *'child/'* ]]; then
  pass ncurses-render 'real terminal rows contain compact names and right-edge metadata'
else
  fail ncurses-render 'Dirvish metadata did not reach the terminal screen'
fi

tmux_cmd resize-window -t "$session" -x 64 -y 24
sleep 0.5
lem_keys "$session" F2
if wait_report '^DISPLAY width=64 file-cells=64 file-tail=..1\.5k file-size=..1\.5k file-source=..size\.bin directory-cells=64 directory-tail=.....3 directory-size=.....3 directory-source=..child/ modified=no readonly=yes$'; then
  pass resize 'metadata followed the narrower window without entering source text'
else
  fail resize '64-column alignment or source invariants differed'
fi

lem_keys "$session" C-c H
if wait_report '^ORDINARY header=yes blank=yes modeline=yes sort=yes index=yes selected=yes$'; then
  pass ordinary-chrome 'ordinary directory visits show the path, hide the blank row, and expose pinned footer data'
else
  fail ordinary-chrome 'ordinary directory header visibility or modeline segments differed'
fi

lem_keys "$session" F3
if wait_report '^VISIT file=open\.txt text=DIRVISH VISIT$'; then
  pass visit 'the compact property-backed row opened the exact file'
else
  fail visit 'presentation changes broke directory row identity'
fi

lem_keys "$session" F4
if wait_report '^RELOAD inserters=1 exact=yes transformer=yes$'; then
  pass reload 'two source reloads retained one inserter and the composite transformer'
else
  fail reload 'reload duplicated or displaced presentation state'
fi

tmux_cmd resize-window -t "$session" -x 120 -y 30
sleep 0.5
lem_keys "$session" F5
if wait_report '^FULL windows=3 widths=13,41,64 modes=DIRECTORY-MODE,DIRECTORY-MODE,FUNDAMENTAL-MODE focus=root command=yes preview-parent=yes readonly=yes$'; then
  pass fullframe 'M-x command built the pinned one-parent/current/preview layout'
else
  fail fullframe 'full-frame layout, focus, command registration, or initial preview differed'
fi

lem_keys "$session" C-c H
if wait_report '^CHROME header=source navigable=3 path=yes blank=yes footer=yes preview=blank$'; then
  pass fullframe-chrome 'the visible path row and pinned footer segments preserve the existing session topology'
else
  fail fullframe-chrome 'full-frame path visibility, blank-row hiding, or footer segments differed'
fi

screen="$(lem_capture "$session")"
if [[ "$screen" == *'open.txt'* ]] &&
   [[ "$screen" == *'name|mtime'* ]]; then
  pass fullframe-render 'the real terminal displayed directory, preview, and Dirvish chrome together'
else
  fail fullframe-render 'the three-pane layout or its footer did not reach the real terminal'
fi

lem_keys "$session" n n n
sleep 0.8
lem_keys "$session" F6
if wait_report '^PREVIEW row=open\.txt path=open\.txt text=yes readonly=yes timer=idle$'; then
  pass preview 'physical directory movement drove a debounced safe text preview'
else
  fail preview 'selection and preview content did not converge after physical movement'
fi

lem_keys "$session" Enter
sleep 0.3
lem_keys "$session" F7
if wait_report '^OPEN session=no file=open\.txt shape=restored side=preserved selected=open\.txt$'; then
  pass open-restore 'Return restored the prior topology before opening the selected file'
else
  fail open-restore 'file activation stranded panes or disturbed unrelated windows'
fi

lem_keys "$session" F8
if wait_report '^QUIT-READY session=yes$'; then
  pass quit-ready 'a second full-frame session started from a nested layout'
else
  fail quit-ready 'could not prepare the physical q restoration probe'
fi

lem_keys "$session" F4
if wait_report '^RELOAD inserters=1 exact=yes transformer=yes$' 5; then
  :
fi
lem_keys "$session" q
sleep 0.3
lem_keys "$session" F9
if wait_report '^QUIT session=no tree=restored selected=DIRVISH-ORIGIN-B preview-live=no$'; then
  pass quit-restore 'q survived source reload and restored the exact prior window tree'
else
  fail quit-restore 'q failed to restore selection, buffers, geometry, or preview ownership'
fi

lem_keys "$session" F10
if wait_report '^TOGGLE session=no shape=restored selected-mode=DIRECTORY-MODE sides=preserved$'; then
  pass layout-toggle 'layout-toggle kept the directory while restoring companion windows'
else
  fail layout-toggle 'layout-toggle did not preserve the ordinary directory workflow'
fi

lem_keys "$session" F11
if wait_report '^SAFE binary=yes special=yes bounded=yes eof=yes archive=yes epub=yes pdf=yes media=yes oversized=yes debounce=20 throttle=250 limit=200 timeout=3 output=524288 input=134217728$'; then
  pass preview-boundaries 'binary, special, directory, archive, document, and media previews stayed bounded'
else
  fail preview-boundaries 'preview safety or pinned scheduling bounds differed'
fi

lem_keys "$session" C-c D
if wait_report '^DERIVED-READY row=open\.txt session=yes$'; then
  pass derived-ready 'prepared a full-frame session before physical preview movement'
else
  fail derived-ready 'could not prepare the derived-preview movement fixture'
fi

lem_keys "$session" n
if lem_wait_for "$session" 'Archive members' 15 >/dev/null; then
  lem_keys "$session" C-c R
  if wait_report '^DERIVED row=preview-archive;safe\.zip archive=yes epub=no pdf=no media=no extracted=no request=idle$'; then
    pass archive-preview 'physical movement listed archive members without extraction'
  else
    fail archive-preview 'archive preview state or async ownership differed'
  fi
else
  fail archive-preview 'archive member list did not reach the terminal preview'
fi

lem_keys "$session" n
if lem_wait_for "$session" 'Dirvish EPUB body' 15 >/dev/null; then
  lem_keys "$session" C-c R
  if wait_report '^DERIVED row=preview-book\.epub archive=no epub=yes pdf=no media=no extracted=no request=idle$'; then
    pass epub-preview 'physical movement rendered bounded EPUB text through Pandoc'
  else
    fail epub-preview 'EPUB preview state or async ownership differed'
  fi
else
  fail epub-preview 'EPUB text did not reach the terminal preview'
fi

lem_keys "$session" n
if lem_wait_for "$session" 'PNG image data' 15 >/dev/null; then
  lem_keys "$session" C-c R
  if wait_report '^DERIVED row=preview-image\.png archive=no epub=no pdf=no media=yes extracted=no request=idle$'; then
    pass media-preview 'physical movement rendered safe image metadata'
  else
    fail media-preview 'media preview state or async ownership differed'
  fi
else
  fail media-preview 'image metadata did not reach the terminal preview'
fi

lem_keys "$session" n
if lem_wait_for "$session" 'Dirvish PDF Page' 15 >/dev/null; then
  lem_keys "$session" C-c R
  if wait_report '^DERIVED row=preview-paper\.pdf archive=no epub=no pdf=yes media=no extracted=no request=idle$'; then
    pass pdf-preview 'physical movement rendered the bounded first PDF page'
  else
    fail pdf-preview 'PDF preview state or async ownership differed'
  fi
else
  fail pdf-preview 'PDF first-page text did not reach the terminal preview'
fi

lem_keys "$session" n n n n n
sleep 0.3
lem_keys "$session" C-c S
if wait_report '^SYMLINK row=zz-symlink-open segment=yes target=yes$'; then
  pass symlink-segment 'physical last-entry movement exposed the selected symlink target'
else
  fail symlink-segment 'the selected symlink target did not reach the footer'
fi

lem_keys "$session" q
sleep 0.3

lem_keys "$session" Escape Escape M-x
if lem_wait_for "$session" 'Command:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'dirvish'
  sleep 0.3
  lem_keys "$session" Enter
  sleep 0.5
  lem_keys "$session" F12
  if wait_report '^MX session=yes windows=3 focus=root selected-mode=DIRECTORY-MODE preview-live=yes$'; then
    pass mx-command 'physical M-x dirvish opened the full-frame session'
  else
    fail mx-command 'the physical command route did not open or focus Dirvish'
  fi
else
  fail mx-command 'M-x did not open the command prompt'
fi

lem_keys "$session" q
sleep 0.3
lem_keys "$session" F12
if wait_report '^MX session=no windows=3 focus=other selected-mode=FUNDAMENTAL-MODE preview-live=no$'; then
  pass mx-quit 'physical q restored the command-origin layout and removed its preview'
else
  fail mx-quit 'the physical command session did not restore and clean up exactly'
fi

if ((failed)); then
  exit 1
fi

printf '\n%s\n' 'DIRVISH TEST PASSED'
