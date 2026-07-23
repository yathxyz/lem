#!/usr/bin/env bash
# Deterministic interactive child for the real-ncurses terminal gate.
set -u

if [[ -n ${LEM_YATH_TERMINAL_CHILD_PID_FILE:-} ]]; then
  printf '%s\n' "$$" >"$LEM_YATH_TERMINAL_CHILD_PID_FILE"
fi

printf 'SHELL-READY cwd=<%s>\n' "$PWD"

buffer=
while IFS= read -r -n 1 character; do
  if [[ $character == $'\e' ]]; then
    printf 'ESC-RECEIVED\n'
  elif [[ -z $character ]]; then
    printf 'COMMAND:<%s> cwd=<%s>\n' "$buffer" "$PWD"
    if [[ $buffer == exit ]]; then
      exit 0
    fi
    buffer=
  else
    buffer+=$character
  fi
done
