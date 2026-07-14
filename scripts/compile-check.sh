#!/usr/bin/env bash
# Force-recompile the lem-yath system inside Lem, dumping full compiler
# diagnostics to a log (the TUI swallows them otherwise).
# Safe to run concurrently: names are unique per invocation.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-$$}"
session="lem-yath-compile-$id"
tmp="${TMPDIR:-/tmp}"
log="$tmp/lem-yath-compile-$id.log"
form="$tmp/lem-yath-compile-check-$id.lisp"
check_src="$tmp/lem-yath-compile-src-$id"

rm -rf "$check_src"
cp -R "$LEM_YATH_SOURCE" "$check_src"
chmod -R u+w "$check_src"
LEM_YATH_SOURCE="$check_src"
LEM_YATH_ASDF_CACHE="$tmp/lem-yath-asdf-$id"
lem-yath_configure_asdf_output

cleanup() {
  lem_stop "$session"
  rm -rf "$form" "$check_src" "$LEM_YATH_ASDF_CACHE"
}
trap cleanup EXIT INT TERM

cat > "$form" <<EOF
(with-open-file (s "$log" :direction :output :if-exists :supersede)
  (let ((*error-output* s)
        (*standard-output* s))
    (handler-case
        (progn
          ;; The packaged Lem image may already know the installed system.
          ;; Clear that registry entry so this check cannot silently compile
          ;; an immutable store copy instead of CHECK_SRC.
          (asdf:clear-system "lem-yath")
          (asdf:load-asd #P"$check_src/lem-yath.asd")
          (asdf:load-system "lem-yath" :force t)
          (format s "~%LOAD OK~%"))
      (error (e) (format s "~%TOP-ERROR: ~a~%" e)))
    (finish-output s)))
EOF

rm -f "$log"
lem_start "$session" -q --eval "(load \"$form\")"
for _ in $(seq 1 240); do
  [ -f "$log" ] && grep -qE 'LOAD OK|TOP-ERROR' "$log" && break
  sleep 0.5
done
cat "$log" 2>/dev/null || echo "no log produced"
grep -q 'LOAD OK' "$log" 2>/dev/null
