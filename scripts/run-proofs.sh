#!/usr/bin/env bash
# scripts/run-proofs.sh -- Certify every ACL2 book under verified/ (SPEC-VK V0-2).
#
# Proofs are CI-gated exactly like rove tests (SPEC-VK Constraint 1): a red proof
# blocks commit. Run this in the same pre-commit habit as scripts/run-tests.sh.
#
# CRITICAL (empirically verified): the ACL2 binary EXITS 0 EVEN WHEN A PROOF
# FAILS -- it simply does not write the book's .cert file. Therefore this script
# gates on .cert EXISTENCE/FRESHNESS, never on ACL2's exit status.
#
# Behaviour:
#   * certifies each verified/*.lisp book (shim files are skipped),
#   * incremental: skips a book whose .cert is newer than both its .lisp source
#     AND the shim (shim changes can invalidate the dual-load contract),
#   * writes a per-book log to verified/<book>.cert.out,
#   * exits nonzero iff any book failed to certify.
#
# ACL2 binary resolution order: $ACL2, then `command -v acl2`, then the pinned
# nixpkgs store path (see verified/README.md).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERIFIED="$ROOT/verified"
SHIM="$VERIFIED/shim.lisp"

# Full ACL2 (WITH certified community books -- std/, arithmetic/, ...); kernel
# books may (include-book "std/lists/top" :dir :system). See verified/README.md.
PINNED_ACL2=/nix/store/pcm6pnmxikvnk9pg9abs6k3c0yamsqkj-acl2-8.6/bin/acl2
# Books-free fallback (nixpkgs acl2-minimal): certifies only books with no
# include-book :dir :system.
PINNED_ACL2_MINIMAL=/nix/store/ymb6xzcij4c22all84pcafvjv4wgvf9s-acl2-8.6/bin/acl2

resolve_acl2() {
  if [ -n "${ACL2:-}" ]; then
    printf '%s\n' "$ACL2"; return 0
  fi
  if [ -x "$PINNED_ACL2" ]; then
    printf '%s\n' "$PINNED_ACL2"; return 0
  fi
  if command -v acl2 >/dev/null 2>&1; then
    command -v acl2; return 0
  fi
  if [ -x "$PINNED_ACL2_MINIMAL" ]; then
    printf '%s\n' "$PINNED_ACL2_MINIMAL"; return 0
  fi
  echo "run-proofs: no ACL2 binary found (set \$ACL2, put acl2 on PATH, or install the pinned build)" >&2
  return 1
}

ACL2_BIN="$(resolve_acl2)"
echo "run-proofs: using ACL2 = $ACL2_BIN"

fail=0
certified=0
skipped=0

# Dependency order: certify-book needs included books certified first, and the
# glob is alphabetical (buffer-edit would sort before the buffer-model book it
# includes). Books listed here certify first, in this order; any book not
# listed follows in glob order.
ORDERED_BOOKS=(hello buffer-model buffer-edit undo codec crash-safety input-decode eastasian-data width)

ordered_paths=()
for name in "${ORDERED_BOOKS[@]}"; do
  [ -f "$VERIFIED/$name.lisp" ] && ordered_paths+=("$VERIFIED/$name.lisp")
done
shopt -s nullglob
for book in "$VERIFIED"/*.lisp; do
  name="$(basename "${book%.lisp}")"
  listed=0
  for n in "${ORDERED_BOOKS[@]}"; do
    [ "$n" = "$name" ] && listed=1 && break
  done
  [ "$listed" -eq 0 ] && ordered_paths+=("$book")
done
shopt -u nullglob

for book in "${ordered_paths[@]}"; do
  case "$(basename "$book")" in
    shim.lisp|shim-*.lisp) continue ;;
  esac

  base="${book%.lisp}"
  name="$(basename "$base")"
  cert="$base.cert"
  log="$base.cert.out"

  # Incremental skip: cert newer than the shim and EVERY book source (a book
  # may include a sibling book, so any source change conservatively invalidates
  # all certs; with a handful of books this stays cheap and correct).
  fresh=1
  if [ -f "$cert" ] && [ "$cert" -nt "$SHIM" ]; then
    for src in "$VERIFIED"/*.lisp; do
      if [ ! "$cert" -nt "$src" ]; then
        fresh=0
        break
      fi
    done
  else
    fresh=0
  fi
  if [ "$fresh" -eq 1 ]; then
    echo "run-proofs: SKIP  $name (up to date)"
    skipped=$((skipped + 1))
    continue
  fi

  echo "run-proofs: CERT  $name ..."
  rm -f "$cert"
  # ACL2 exit status is meaningless here (always 0); we check for the .cert next.
  (cd "$VERIFIED" && printf '(certify-book "%s" 0)\n' "$name" | "$ACL2_BIN") \
    >"$log" 2>&1 || true

  if [ -f "$cert" ]; then
    echo "run-proofs: OK    $name"
    certified=$((certified + 1))
  else
    echo "run-proofs: FAIL  $name  (see $log)" >&2
    fail=1
  fi
done

echo "run-proofs: certified=$certified skipped=$skipped failed=$([ "$fail" -eq 0 ] && echo 0 || echo yes)"
exit "$fail"
