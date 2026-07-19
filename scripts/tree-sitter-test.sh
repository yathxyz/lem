#!/usr/bin/env bash
# Real installed-Lem coverage for configured treesit-auto-style highlighting.
set -uo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-tree-sitter-$$}"
session="lem-yath-tree-sitter-$id"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-tree-sitter.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export WORKDIR="$root/work"
export LEM_YATH_TREE_SITTER_REPORT="$root/report"
export LEM_YATH_TREE_SITTER_FILE="$root/main.py"
export LEM_YATH_LANGUAGE_MODE_ROOT="$root/languages"
mkdir -p \
  "$HOME" \
  "$XDG_CACHE_HOME" \
  "$WORKDIR" \
  "$LEM_YATH_LANGUAGE_MODE_ROOT/nginx/sites"
: >"$LEM_YATH_TREE_SITTER_REPORT"

cleanup() {
  lem_stop "$session" || true
  case "${root:-}" in
    */lem-yath-tree-sitter.*) rm -rf -- "$root" ;;
    *) printf 'Refusing unsafe tree-sitter cleanup path: %s\n' \
         "${root:-<unset>}" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

printf '%s\n' \
  'lower = "hello"' \
  'Upper = lower' \
  'custom(Upper)' \
  'print(Upper)' \
  'if Upper:' \
  '    pass' \
  >"$LEM_YATH_TREE_SITTER_FILE"

printf '%s\n' 'build:' '    echo ready' \
  >"$LEM_YATH_LANGUAGE_MODE_ROOT/.JuStFiLe"
printf '%s\n' 'test:' '    echo tested' \
  >"$LEM_YATH_LANGUAGE_MODE_ROOT/jUsTfIlE"
printf '%s\n' 'section .text' '_start:' '    mov eax, 1' \
  >"$LEM_YATH_LANGUAGE_MODE_ROOT/program.nasm"
printf '%s\n' "project('fixture')" 'if true' 'endif' \
  >"$LEM_YATH_LANGUAGE_MODE_ROOT/meson.build"
printf '%s\n' "option('feature', type: 'boolean')" \
  >"$LEM_YATH_LANGUAGE_MODE_ROOT/meson_options.txt"
printf '%s\n' "option('alternate', type: 'boolean')" \
  >"$LEM_YATH_LANGUAGE_MODE_ROOT/meson.options"
printf '%s\n' 'server {' '    listen 80;' '}' \
  >"$LEM_YATH_LANGUAGE_MODE_ROOT/nginx.conf"
# The dollar expression is literal nginx source, not shell interpolation.
# shellcheck disable=SC2016
printf '%s\n' 'location / {' '    proxy_set_header Host $host;' '}' \
  >"$LEM_YATH_LANGUAGE_MODE_ROOT/nginx/sites/site.conf"
printf '%s\n' 'upstream backend {' '    server 127.0.0.1;' '}' \
  >"$LEM_YATH_LANGUAGE_MODE_ROOT/magic.conf"
# The dollar expression is literal Nushell source, not shell interpolation.
# shellcheck disable=SC2016
printf '%s\n' 'let answer = 42' 'if $answer > 0 { print yes }' \
  >"$LEM_YATH_LANGUAGE_MODE_ROOT/script.nu"
printf '%s\n' '#!/usr/bin/env nu' 'let answer = 42' \
  >"$LEM_YATH_LANGUAGE_MODE_ROOT/nu-script"
printf '%s\n' '= Heading' '#let answer = 42' \
  >"$LEM_YATH_LANGUAGE_MODE_ROOT/document.typ"
printf '%s\n' 'extends Node' 'func ready():' $'\tpass' \
  >"$LEM_YATH_LANGUAGE_MODE_ROOT/player.gd"

fixture="$(lem-yath_lisp_string "$here/scripts/tree-sitter-fixture.lisp")"
lem_start "$session" "$LEM_YATH_TREE_SITTER_FILE" --eval "(load #P$fixture)"

for _ in $(seq 1 480); do
  if grep -q '^SUMMARY ' "$LEM_YATH_TREE_SITTER_REPORT" 2>/dev/null; then
    break
  fi
  sleep 0.25
done

if ! grep -q '^SUMMARY ' "$LEM_YATH_TREE_SITTER_REPORT" 2>/dev/null; then
  printf 'TREE-SITTER TEST FAILED: Lem produced no summary\n' >&2
  lem_capture "$session" >&2 || true
  sed -n '1,260p' "$LEM_YATH_TREE_SITTER_REPORT" >&2 || true
  exit 1
fi

sed -n '1,320p' "$LEM_YATH_TREE_SITTER_REPORT"
if ! grep -q '^SUMMARY PASS failures=0 grammars=24/24$' \
  "$LEM_YATH_TREE_SITTER_REPORT"; then
  exit 1
fi

tmux_cmd send-keys -t "$session" F12 i
tmux_cmd send-keys -t "$session" -l 'project'
if lem_wait_for "$session" 'project.*Meson builtin function' 10 >/dev/null; then
  printf 'PASS meson-physical-global-completion\n'
else
  printf 'FAIL meson-physical-global-completion\n' >&2
  exit 1
fi

if lem_wait_for \
     "$session" 'void project\(project_name, list_of_languages, \.\.\.\)' \
     10 >/dev/null; then
  printf 'PASS meson-physical-completion-documentation\n'
else
  printf 'FAIL meson-physical-completion-documentation\n' >&2
  exit 1
fi

tmux_cmd send-keys -t "$session" Enter
tmux_cmd send-keys -t "$session" -l "('fixture'"
sleep 1
tmux_cmd send-keys -t "$session" F11
for _ in $(seq 1 40); do
  if grep -q '^MESON-PHYSICAL text=.*project.*fixture.* mode=MESON-MODE .*eldoc=.*void project.*' \
       "$LEM_YATH_TREE_SITTER_REPORT"; then
    break
  fi
  sleep 0.25
done
if grep -q '^MESON-PHYSICAL text=.*project.*fixture.* mode=MESON-MODE .*eldoc=.*void project.*' \
     "$LEM_YATH_TREE_SITTER_REPORT"; then
  printf 'PASS meson-physical-idle-signature\n'
else
  printf 'FAIL meson-physical-idle-signature\n' >&2
  grep '^MESON-PHYSICAL ' "$LEM_YATH_TREE_SITTER_REPORT" >&2 || true
  lem_capture "$session" >&2 || true
  exit 1
fi

tmux_cmd send-keys -t "$session" F10
if ! lem_wait_for "$session" "executable.*fixture" 10 >/dev/null; then
  printf 'FAIL meson-physical-keyword-argument-setup\n' >&2
  lem_capture "$session" >&2 || true
  exit 1
fi
tmux_cmd send-keys -t "$session" -l 'dep'
if lem_wait_for "$session" 'dependencies.*Meson keyword argument' 10 >/dev/null; then
  printf 'PASS meson-physical-keyword-argument-completion\n'
else
  printf 'FAIL meson-physical-keyword-argument-completion\n' >&2
  exit 1
fi
