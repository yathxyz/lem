#!/usr/bin/env bash
set -euo pipefail

control=${LEM_YATH_SOPS_CONTROL:?}
command=${1:?}
shift

case "$command" in
  --version)
    if grep -qx 'old-version' "$control" 2>/dev/null; then
      printf 'sops 3.8.9\n'
    elif grep -qx 'malformed-version' "$control" 2>/dev/null; then
      printf 'sops development build\n'
    else
      printf 'sops 3.13.1\n'
    fi
    ;;
  filestatus)
    file=${1:?}
    if grep -Eq '(^sops:|"sops")' "$file"; then
      printf '{"encrypted":true}\n'
    else
      printf '{"encrypted":false}\n'
    fi
    ;;
  decrypt)
    file=${1:?}
    if grep -qx 'decrypt-fail' "$control" 2>/dev/null; then
      printf '%s\n' 'ZYZZYVA-SOPS-ERROR-MUST-NOT-RENDER' >&2
      exit 7
    fi
    if grep -q 'ciphertext: SECOND' "$file"; then
      printf 'token: SECOND-SECRET\ntrailing: keep   \n'
    elif [[ $file == *failed.yaml ]]; then
      printf 'token: RECOVERED-SECRET\ntrailing: keep   \n'
    else
      printf 'token: ZYZZYVA-PLAINTEXT\ntrailing: keep   \n'
    fi
    ;;
  encrypt)
    if [[ ${1:-} != --filename-override ]]; then
      exit 64
    fi
    shift 2
    plaintext=$(sed -n '1,$p')
    if grep -qx 'encrypt-fail' "$control" 2>/dev/null; then
      printf '%s\n' 'ZYZZYVA-SOPS-ERROR-MUST-NOT-RENDER' >&2
      exit 8
    fi
    marker=BASE
    grep -Fq 'Welcome to SOPS!' <<<"$plaintext" && marker=CREATED
    grep -Fq 'EDITED-SOPS' <<<"$plaintext" && marker=EDITED
    grep -Fq 'FAILURE-RETAINED' <<<"$plaintext" && marker=RECOVERED
    grep -Fq 'FIRST-SAVE-FAILURE' <<<"$plaintext" && marker=CREATE-RECOVERED
    trailing=no
    grep -Fq 'trailing: keep   ' <<<"$plaintext" && trailing=yes
    printf 'sops:\n  mac: fake\nciphertext: %s\ntrailing-preserved: %s\n' "$marker" "$trailing"
    ;;
  *)
    exit 64
    ;;
esac
