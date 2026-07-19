#!/usr/bin/env bash
set -uo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-rectangle-$$}"
session="lem-yath-rectangle-$id"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-rectangle.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_RECTANGLE_REPORT="$root/report"
file="$root/rectangle.txt"
mkdir -p "$HOME" "$XDG_CACHE_HOME"
: >"$LEM_YATH_RECTANGLE_REPORT"
printf '%s\n' abcdef xy 123456 >"$file"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-rectangle.*) rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe rectangle cleanup path: %s\n' \
         "${root:-<unset>}" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fixture="$(lem-yath_lisp_string "$here/scripts/rectangle-fixture.lisp")"
lem_start_lem-yath_eval "$session" "(load #P$fixture)" "$file"

for _ in $(seq 1 240); do
  grep -q '^SUMMARY ' "$LEM_YATH_RECTANGLE_REPORT" 2>/dev/null && break
  sleep 0.25
done
if ! grep -q '^SUMMARY PASS failures=0$' "$LEM_YATH_RECTANGLE_REPORT"; then
  printf 'FAIL rectangle-static\n' >&2
  cat "$LEM_YATH_RECTANGLE_REPORT" >&2
  lem_capture "$session" >&2 || true
  exit 1
fi
cat "$LEM_YATH_RECTANGLE_REPORT"

if ! lem_wait_for "$session" 'NORMAL.*rectangle.txt' 30 >/dev/null; then
  printf 'FAIL rectangle-boot\n' >&2
  exit 1
fi

lem_keys "$session" F9 C-x Space 2 j 3 l 2 M-j F8
for _ in $(seq 1 80); do
  grep -q '^PHYSICAL-DUPLICATE ' "$LEM_YATH_RECTANGLE_REPORT" && break
  sleep 0.25
done
if grep -q '^PHYSICAL-DUPLICATE text=yes mode=yes anchor=1:2 point=3:5 overlays=3$' \
     "$LEM_YATH_RECTANGLE_REPORT"; then
  printf 'PASS rectangle-physical-duplicate\n'
else
  printf 'FAIL rectangle-physical-duplicate\n' >&2
  tail -n 20 "$LEM_YATH_RECTANGLE_REPORT" >&2
  lem_capture "$session" >&2 || true
  exit 1
fi

lem_keys "$session" u F7
for _ in $(seq 1 80); do
  grep -q '^PHYSICAL-UNDO ' "$LEM_YATH_RECTANGLE_REPORT" && break
  sleep 0.25
done
if grep -q '^PHYSICAL-UNDO text=yes mode=no$' "$LEM_YATH_RECTANGLE_REPORT"; then
  printf 'PASS rectangle-physical-one-step-undo\n'
else
  printf 'FAIL rectangle-physical-one-step-undo\n' >&2
  tail -n 20 "$LEM_YATH_RECTANGLE_REPORT" >&2
  lem_capture "$session" >&2 || true
  exit 1
fi

lem_keys "$session" F9 C-x Space 2 j 3 l C-x r k F6
for _ in $(seq 1 80); do
  grep -q '^PHYSICAL-KILL ' "$LEM_YATH_RECTANGLE_REPORT" && break
  sleep 0.25
done
if grep -q '^PHYSICAL-KILL text=yes mode=no killed=yes$' \
     "$LEM_YATH_RECTANGLE_REPORT"; then
  printf 'PASS rectangle-physical-kill\n'
else
  printf 'FAIL rectangle-physical-kill\n' >&2
  tail -n 20 "$LEM_YATH_RECTANGLE_REPORT" >&2
  lem_capture "$session" >&2 || true
  exit 1
fi

lem_keys "$session" F9 C-x Space 2 j 3 l C-x r t
if ! lem_wait_for "$session" 'String rectangle:' 10 >/dev/null; then
  printf 'FAIL rectangle-physical-string-prompt\n' >&2
  lem_capture "$session" >&2 || true
  exit 1
fi
lem_keys "$session" Z Enter F5
for _ in $(seq 1 80); do
  grep -q '^PHYSICAL-STRING ' "$LEM_YATH_RECTANGLE_REPORT" && break
  sleep 0.25
done
if grep -q '^PHYSICAL-STRING text=yes mode=no point=3:3$' \
     "$LEM_YATH_RECTANGLE_REPORT"; then
  printf 'PASS rectangle-physical-string\n'
else
  printf 'FAIL rectangle-physical-string\n' >&2
  tail -n 20 "$LEM_YATH_RECTANGLE_REPORT" >&2
  lem_capture "$session" >&2 || true
  exit 1
fi

lem_keys "$session" F9 C-x Space 2 j 3 l C-x r t
if ! lem_wait_for "$session" 'String rectangle:' 10 >/dev/null; then
  printf 'FAIL rectangle-physical-string-cancel-prompt\n' >&2
  lem_capture "$session" >&2 || true
  exit 1
fi
lem_keys "$session" Q C-g F4
for _ in $(seq 1 80); do
  grep -q '^PHYSICAL-STRING-CANCEL ' "$LEM_YATH_RECTANGLE_REPORT" && break
  sleep 0.25
done
if grep -q '^PHYSICAL-STRING-CANCEL text=yes mode=yes point=3:5$' \
     "$LEM_YATH_RECTANGLE_REPORT"; then
  printf 'PASS rectangle-physical-string-cancel\n'
else
  printf 'FAIL rectangle-physical-string-cancel\n' >&2
  tail -n 20 "$LEM_YATH_RECTANGLE_REPORT" >&2
  lem_capture "$session" >&2 || true
  exit 1
fi
