#!/usr/bin/env bash
# Installed-Lem acceptance coverage for the Dape-compatible DAP client.
set -uo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-dap-$$}"
session="lem-yath-dap-$id"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-dap.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_DAP_REPORT="$root/report"
export LEM_YATH_DAP_ADAPTER_REPORT="$root/adapter-report"
export LEM_YATH_DAP_FILE="$WORKDIR/main.py"
export LEM_YATH_DAP_CASE_ROOT="$WORKDIR/cases"
export LEM_YATH_DAP_ADAPTER="$here/scripts/fake-dap-adapter.py"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$WORKDIR" \
  "$LEM_YATH_DAP_CASE_ROOT/go" "$LEM_YATH_DAP_CASE_ROOT/c" \
  "$LEM_YATH_DAP_CASE_ROOT/cpp" "$LEM_YATH_DAP_CASE_ROOT/rust"
: >"$LEM_YATH_DAP_REPORT"
: >"$LEM_YATH_DAP_ADAPTER_REPORT"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-dap.*) rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe dap-test cleanup path: %s\n' \
         "${root:-<unset>}" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

for program in clang clang++ debugpy-adapter dlv gdb lldb-dap python python3 \
  rustc; do
  if ! command -v "$program" >/dev/null 2>&1; then
    printf 'FAIL prerequisite: %s is absent from the installed wrapper PATH\n' \
      "$program" >&2
    exit 1
  fi
done

printf '%s\n' \
  'answer = 40' \
  'answer += 2' \
  'print("hello λ", answer)' \
  'assert input() == "continue"' \
  'answer += 1' \
  >"$LEM_YATH_DAP_FILE"

printf '%s\n' \
  'package main' \
  '' \
  'func main() {' \
  '    value := 40' \
  '    value += 2' \
  '    println(value)' \
  '}' \
  >"$LEM_YATH_DAP_CASE_ROOT/go/main.go"
printf '%s\n' \
  'module example.com/lem-yath-dap' \
  'go 1.25' \
  >"$LEM_YATH_DAP_CASE_ROOT/go/go.mod"

printf '%s\n' \
  '#include <stdio.h>' \
  'int main(void) {' \
  '    int value = 40;' \
  '    value += 2;' \
  '    printf("c=%d\n", value);' \
  '    return 0;' \
  '}' \
  >"$LEM_YATH_DAP_CASE_ROOT/c/main.c"

printf '%s\n' \
  '#include <iostream>' \
  'int main() {' \
  '    int value = 40;' \
  '    value += 2;' \
  "    std::cout << \"cpp=\" << value << '\\n';" \
  '    return 0;' \
  '}' \
  >"$LEM_YATH_DAP_CASE_ROOT/cpp/main.cpp"

printf '%s\n' \
  'fn main() {' \
  '    let mut value: i32 = 40;' \
  '    value += 2;' \
  '    value += 0;' \
  '    println!("rust={value}");' \
  '}' \
  >"$LEM_YATH_DAP_CASE_ROOT/rust/main.rs"

clang -g -O0 "$LEM_YATH_DAP_CASE_ROOT/c/main.c" \
  -o "$LEM_YATH_DAP_CASE_ROOT/c/a.out"
clang++ -g -O0 "$LEM_YATH_DAP_CASE_ROOT/cpp/main.cpp" \
  -o "$LEM_YATH_DAP_CASE_ROOT/cpp/a.out"
rustc -g -C opt-level=0 "$LEM_YATH_DAP_CASE_ROOT/rust/main.rs" \
  -o "$LEM_YATH_DAP_CASE_ROOT/rust/a.out"

fixture="$(lem-yath_lisp_string "$here/scripts/dap-fixture.lisp")"
lem_start "$session" "$LEM_YATH_DAP_FILE" --eval "(load #P$fixture)"

for _ in $(seq 1 1600); do
  if grep -q '^SUMMARY ' "$LEM_YATH_DAP_REPORT" 2>/dev/null; then
    break
  fi
  sleep 0.25
done

if ! grep -q '^SUMMARY ' "$LEM_YATH_DAP_REPORT" 2>/dev/null; then
  printf 'DAP TEST FAILED: Lem produced no summary\n' >&2
  lem_capture "$session" >&2 || true
  sed -n '1,360p' "$LEM_YATH_DAP_REPORT" >&2 || true
  sed -n '1,200p' "$LEM_YATH_DAP_ADAPTER_REPORT" >&2 || true
  exit 1
fi

sed -n '1,420p' "$LEM_YATH_DAP_REPORT"

for command in initialize launch setBreakpoints setFunctionBreakpoints \
  setExceptionBreakpoints configurationDone threads stackTrace scopes \
  variables evaluate next gotoTargets goto restart readMemory disassemble \
  disconnect; do
  if ! grep -q "\"command\": \"$command\"" \
      "$LEM_YATH_DAP_ADAPTER_REPORT"; then
    printf 'FAIL adapter-request-%s\n' "$command" >&2
    exit 1
  fi
done

for assertion in \
  'condition|"condition": "answer == 42"' \
  'hit-condition|"hitCondition": ">= 1"' \
  'log-message|"logMessage": "answer={answer}"' \
  'function-breakpoint|"name": "main"' \
  'default-exception-filter|"filters": \["uncaught"\]' \
  'shell-terminal-rejection|"command": "runInTerminal".*"success": false' \
  'shell-terminal-rejection-message|Shell-interpreted terminal arguments are not supported'; do
  label="${assertion%%|*}"
  pattern="${assertion#*|}"
  if ! grep -q "$pattern" "$LEM_YATH_DAP_ADAPTER_REPORT"; then
    printf 'FAIL adapter-assertion-%s\n' "$label" >&2
    exit 1
  fi
done

configuration_count="$(
  grep -c '"command": "configurationDone"' \
    "$LEM_YATH_DAP_ADAPTER_REPORT" || true
)"
if [[ "$configuration_count" -ne 1 ]]; then
  printf 'FAIL configurationDone-count -- expected 1, got %s\n' \
    "$configuration_count" >&2
  exit 1
fi

if ! grep -q '^SUMMARY PASS failures=0$' "$LEM_YATH_DAP_REPORT"; then
  exit 1
fi
