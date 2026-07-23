#!/usr/bin/env bash
# Configured Org HTML export and publishing through the real ncurses editor.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-org-publish-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-org-publish.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export LEM_YATH_ORG_PUBLISH_REPORT="$root/report"
export LEM_YATH_ORG_PUBLISH_TEST_BIN="$root/bin"
export LEM_YATH_ORG_PUBLISH_SLOW="$root/slow-pandoc"
LEM_YATH_REAL_PANDOC="$(command -v pandoc)"
export LEM_YATH_REAL_PANDOC

mkdir -p "$HOME" "$WORKDIR/roam/sub" "$LEM_YATH_ORG_PUBLISH_TEST_BIN"
output="$HOME/proj/web/org-publishing"
outside="$root/outside"
mkdir -p "$outside"

cat >"$LEM_YATH_ORG_PUBLISH_TEST_BIN/pandoc" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ -e "$LEM_YATH_ORG_PUBLISH_SLOW" ]; then
  sleep 30
fi
exec "$LEM_YATH_REAL_PANDOC" "$@"
EOF
sed -i "1c#!$(command -v bash)" "$LEM_YATH_ORG_PUBLISH_TEST_BIN/pandoc"
chmod +x "$LEM_YATH_ORG_PUBLISH_TEST_BIN/pandoc"

cat >"$WORKDIR/roam/index.org" <<'EOF'
:PROPERTIES:
:ID: index-id
:END:
#+TITLE: Publishing Index

* Links
An [[id:target-id][ID target]] and a [[file:sub/target.org::*Target Heading][file target]].

Inline math: \(x^2 + y^2\).

#+begin_src python
print("source-visible")
#+end_src
EOF

cat >"$WORKDIR/roam/sub/target.org" <<'EOF'
#+TITLE: Target Note

* Target Heading
:PROPERTIES:
:ID: target-id
:END:
Target body.
EOF

printf '%s\n' 'body { color: rebeccapurple; }' >"$WORKDIR/site.css"
printf '\211PNG\r\n\032\nfixture' >"$WORKDIR/roam/pixel.png"

fixture="$WORKDIR/roam/index.org"
fixture_lisp="$(lem-yath_lisp_string "$here/scripts/org-publish-fixture.lisp")"
session="lem-org-publish-$id"
failed=0

cleanup() {
  lem_stop "$session" 2>/dev/null || true
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
}

mx() {
  local command="$1"
  tmux_cmd send-keys -t "$session" Escape Escape M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.3
  tmux_cmd send-keys -t "$session" Enter
}

start_editor() {
  lem_start "$session" --eval "(load #P$fixture_lisp)" "$fixture"
  lem_wait_for "$session" 'Publishing Index' 40 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" Escape
  sleep 1
}

restart_editor() {
  lem_stop "$session" 2>/dev/null || true
  start_editor
}

wait_report() {
  local pattern="$1"
  local _
  for _ in $(seq 1 120); do
    if grep -Eq "$pattern" "$LEM_YATH_ORG_PUBLISH_REPORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

: >"$LEM_YATH_ORG_PUBLISH_REPORT"
if ! start_editor; then
  fail startup 'publishing fixture did not open'
  exit 1
fi

mx lem-yath-test-org-publish-bindings
if wait_report '^BINDING C-c C-e LEM-YATH-ORG-EXPORT-DISPATCH$'; then
  pass bindings 'C-c C-e resolves to the GNU Org-style export dispatcher'
else
  fail bindings 'one or more Org export suffixes did not resolve'
  sed -n '/^BINDING /p' "$LEM_YATH_ORG_PUBLISH_REPORT"
fi

mx lem-yath-test-org-publish-insert-live-text
tmux_cmd send-keys -t "$session" C-c C-e h h
if lem_wait_for "$session" 'Exported HTML to' 30 >/dev/null &&
   grep -q 'Live unsaved marker' "$WORKDIR/roam/index.html" &&
   ! grep -q 'Live unsaved marker' "$fixture" &&
   grep -q 'href="sub/target.html#target-id"' "$WORKDIR/roam/index.html" &&
   grep -q 'mathjax' "$WORKDIR/roam/index.html"; then
  pass live-export 'physical h h exports unsaved text, resolved links, and MathJax'
else
  fail live-export 'live HTML export did not preserve the expected semantics'
fi

export LEM_YATH_ORG_PUBLISH_CORE_MODE=incremental
: >"$LEM_YATH_ORG_PUBLISH_REPORT"
if ! restart_editor; then
  fail project-restart 'fresh editor for project dispatch did not open'
  exit 1
fi
if wait_report '^CORE html-written=2 html-skipped=0 static-written=2 static-skipped=0 unresolved=0 ambiguous=0$' &&
   [ -f "$output/index.html" ] &&
   [ -f "$output/sub/target.html" ] &&
   [ -f "$output/site.css" ] &&
   [ -f "$output/roam/pixel.png" ] &&
   grep -q 'href="sub/target.html#target-id"' "$output/index.html" &&
   grep -q 'source-visible' "$output/index.html" &&
   cmp -s "$WORKDIR/site.css" "$output/site.css" &&
   cmp -s "$WORKDIR/roam/pixel.png" "$output/roam/pixel.png"; then
  pass project 'packaged Lem publishes notes, ID links, file links, and assets'
else
  fail project 'composite publishing output was incomplete or incorrect'
  sed -n '/^CORE/p' "$LEM_YATH_ORG_PUBLISH_REPORT"
fi

before_inode="$(stat -c %i "$output/index.html" 2>/dev/null || printf missing)"
: >"$LEM_YATH_ORG_PUBLISH_REPORT"
if ! restart_editor; then
  fail incremental-restart 'fresh editor for incremental check did not open'
  exit 1
fi
if wait_report '^CORE html-written=0 html-skipped=2 static-written=0 static-skipped=2 unresolved=0 ambiguous=0$' &&
   [ "$(stat -c %i "$output/index.html")" = "$before_inode" ]; then
  pass incremental 'unchanged outputs are skipped without replacement'
else
  fail incremental 'incremental publishing rewrote or missed unchanged outputs'
fi

export LEM_YATH_ORG_PUBLISH_CORE_MODE=force
: >"$LEM_YATH_ORG_PUBLISH_REPORT"
if ! restart_editor; then
  fail force-restart 'fresh editor for force check did not open'
  exit 1
fi
if wait_report '^CORE html-written=2 html-skipped=0 static-written=2 static-skipped=0 unresolved=0 ambiguous=0$' &&
   [ "$(stat -c %i "$output/index.html")" != "$before_inode" ]; then
  pass force 'force publishing atomically replaces every configured output'
else
  fail force 'force publishing did not replace the expected outputs'
fi

export LEM_YATH_ORG_PUBLISH_CORE_MODE=cancel
: >"$LEM_YATH_ORG_PUBLISH_REPORT"
if ! restart_editor; then
  fail cancellation-restart 'fresh editor for cancellation check did not open'
  exit 1
fi
if wait_report '^CORE-CANCELLED$'; then
  pass cancellation 'a cancelled request performs no remaining publishing work'
else
  fail cancellation 'cancelled publishing did not converge to cancellation'
fi

mkdir -p "$WORKDIR/roam/escape"
cat >"$WORKDIR/roam/escape/evil.org" <<'EOF'
#+TITLE: Escape
This must not leave the publishing root.
EOF
rm -rf "$output/escape"
ln -s "$outside" "$output/escape"
export LEM_YATH_ORG_PUBLISH_CORE_MODE=force
: >"$LEM_YATH_ORG_PUBLISH_REPORT"
if ! restart_editor; then
  fail symlink-restart 'fresh editor for symlink check did not open'
  exit 1
fi
if wait_report '^CORE-ERROR Publishing output (component is not a directory|directory escaped its root)' &&
   [ ! -e "$outside/evil.html" ]; then
  pass symlink-safety 'an output-directory symlink cannot redirect publication'
else
  fail symlink-safety 'publishing followed or failed to reject an output symlink'
  sed -n '/^CORE/p' "$LEM_YATH_ORG_PUBLISH_REPORT"
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf 'Org publishing TUI checks passed.\n'
