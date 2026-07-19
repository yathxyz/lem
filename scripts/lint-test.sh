#!/usr/bin/env bash
# Real installed-Lem acceptance coverage for Flycheck-style diagnostics.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-lint-$$}"
session="lem-yath-lint-$id"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-lint.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_LINT_ROOT="$root/fixtures"
export LEM_YATH_LINT_REPORT="$root/report"
export LEM_YATH_LINT_EVENTS="$root/events"
export LEM_YATH_LINT_FAKE_BIN="$root/fake-bin"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" \
  "$LEM_YATH_LINT_ROOT/go" "$LEM_YATH_LINT_ROOT/rust/src" \
  "$LEM_YATH_LINT_FAKE_BIN"
: >"$LEM_YATH_LINT_REPORT"
: >"$LEM_YATH_LINT_EVENTS"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-lint.*) rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe lint-test cleanup path: %s\n' \
         "${root:-<unset>}" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

for program in bash cargo clang go gofmt mypy nix-instantiate python3 ruff timeout; do
  if ! command -v "$program" >/dev/null 2>&1; then
    printf 'FAIL prerequisites: %s is not on the installed wrapper PATH\n' \
      "$program" >&2
    exit 1
  fi
done

if [ ! -x "$here/scripts/fake-ruff.py" ]; then
  printf 'FAIL prerequisites: scripts/fake-ruff.py is not executable\n' >&2
  exit 1
fi
printf '#!%s\nexec %q %q "$@"\n' \
  "$(command -v bash)" \
  "$(command -v python3)" \
  "$here/scripts/fake-ruff.py" \
  >"$LEM_YATH_LINT_FAKE_BIN/ruff"
chmod +x "$LEM_YATH_LINT_FAKE_BIN/ruff"

printf '%s\n' \
  'import os' \
  'value: int = "text"' \
  >"$LEM_YATH_LINT_ROOT/main.py"
printf '%s\n' 'int main(void) { return missing; }' \
  >"$LEM_YATH_LINT_ROOT/main.c"
printf '%s\n' 'if true; then' '  echo nope' \
  >"$LEM_YATH_LINT_ROOT/main.sh"
printf '%s\n' '{"value": }' >"$LEM_YATH_LINT_ROOT/main.json"
printf '%s\n' '{ value = ; }' >"$LEM_YATH_LINT_ROOT/default.nix"
printf '%s\n' 'module example.com/lem-yath-lint' 'go 1.20' \
  >"$LEM_YATH_LINT_ROOT/go/go.mod"
printf '%s\n' \
  'package main' \
  '' \
  'func main() {' \
  '    println(missing)' \
  '}' \
  >"$LEM_YATH_LINT_ROOT/go/main.go"
printf '%s\n' \
  '[package]' \
  'name = "lem-yath-lint"' \
  'version = "0.1.0"' \
  'edition = "2021"' \
  >"$LEM_YATH_LINT_ROOT/rust/Cargo.toml"
printf '%s\n' \
  'fn main() {' \
  '    let value: i32 = "text";' \
  '    println!("{value}");' \
  '}' \
  >"$LEM_YATH_LINT_ROOT/rust/src/main.rs"

fixture="$(lem-yath_lisp_string "$here/scripts/lint-fixture.lisp")"
python_file="$LEM_YATH_LINT_ROOT/main.py"
lem_start "$session" --eval "(load #P$fixture)" "$python_file"

for _ in $(seq 1 1200); do
  if grep -q '^SUMMARY ' "$LEM_YATH_LINT_REPORT" 2>/dev/null; then
    break
  fi
  sleep 0.25
done

if ! grep -q '^SUMMARY ' "$LEM_YATH_LINT_REPORT" 2>/dev/null; then
  printf 'LINT TEST FAILED: Lem produced no summary\n' >&2
  lem_capture "$session" >&2 || true
  sed -n '1,260p' "$LEM_YATH_LINT_REPORT" >&2 || true
  exit 1
fi

cat "$LEM_YATH_LINT_REPORT"
grep -q '^SUMMARY PASS ' "$LEM_YATH_LINT_REPORT"
