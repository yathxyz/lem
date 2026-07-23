#!/usr/bin/env python3
"""Validate the behavior-level Emacs-to-Lem parity ledger."""

from __future__ import annotations

import csv
import re
import sys
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
LEDGER = ROOT / "docs" / "parity-ledger.tsv"

HEADER = [
    "id",
    "area",
    "emacs_source",
    "activation",
    "priority",
    "target_semantics",
    "disposition",
    "implementation",
    "dependencies",
    "divergence",
    "verification_state",
    "verification_evidence",
    "blocked_by",
    "notes",
]

ACTIVATIONS = {
    "startup",
    "hook",
    "keybound",
    "command",
    "host-gated",
    "declared-only",
    "dead",
}
PRIORITIES = {"P0", "P1", "P2", "P3"}
DISPOSITIONS = {"exact", "approximation", "gap", "n-a", "unassessed"}
VERIFICATION_STATES = {
    "automated",
    "manual",
    "source-only",
    "blocked",
    "none",
    "n-a",
}
EXPECTED_AREAS = [
    "01-keybindings",
    "02-editing",
    "03-completion",
    "04-ide-language-tooling",
    "05-vcs",
    "06-ui",
    "07-org-notes",
    "08-apps",
    "09-ai",
    "10-misc",
    "11-priorities",
    "appendix-declared-packages",
]

ID_RE = re.compile(r"^[A-Z][A-Z0-9]*-[0-9]{3}$")
AREA_RE = re.compile(r"^(?:[0-9]{2}|appendix)-[a-z0-9-]+$")
PATH_LIKE_RE = re.compile(r"(?:^|/)[^/]+\.[A-Za-z0-9]+(?:#.*)?$")
SKIP_PATH_PREFIXES = ("none", "upstream:", "external:")


def split_refs(value: str) -> list[str]:
    return [part for part in value.split(";") if part]


def path_from_ref(ref: str) -> Path | None:
    """Return the repository path named by a ledger reference, if any."""
    if ref == "none" or ref.startswith(SKIP_PATH_PREFIXES[1:]):
        return None
    if ref.startswith("approved:"):
        ref = ref.removeprefix("approved:")
    path_text = ref.split("#", 1)[0]
    if not PATH_LIKE_RE.search(path_text):
        return None
    path = Path(path_text)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"unsafe repository path {path_text!r}")
    return path


def validate_path_refs(
    row_number: int, field: str, value: str, errors: list[str]
) -> None:
    for ref in split_refs(value):
        try:
            relative = path_from_ref(ref)
        except ValueError as error:
            errors.append(f"row {row_number} {field}: {error}")
            continue
        if relative is not None and not (ROOT / relative).exists():
            errors.append(
                f"row {row_number} {field}: referenced path does not exist: {relative}"
            )


def validate_row(row_number: int, row: dict[str, str], errors: list[str]) -> None:
    row_id = row["id"] or f"row-{row_number}"

    for field in HEADER:
        value = row[field]
        if not value:
            errors.append(f"row {row_number} ({row_id}): empty required field {field}")
        elif value != value.strip():
            errors.append(
                f"row {row_number} ({row_id}): {field} has surrounding whitespace"
            )

    if not ID_RE.fullmatch(row["id"]):
        errors.append(f"row {row_number}: invalid id {row['id']!r}")
    if not AREA_RE.fullmatch(row["area"]):
        errors.append(f"row {row_number} ({row_id}): invalid area {row['area']!r}")
    if row["activation"] not in ACTIVATIONS:
        errors.append(
            f"row {row_number} ({row_id}): invalid activation {row['activation']!r}"
        )
    if row["priority"] not in PRIORITIES:
        errors.append(
            f"row {row_number} ({row_id}): invalid priority {row['priority']!r}"
        )
    if row["disposition"] not in DISPOSITIONS:
        errors.append(
            f"row {row_number} ({row_id}): invalid disposition "
            f"{row['disposition']!r}"
        )
    if row["verification_state"] not in VERIFICATION_STATES:
        errors.append(
            f"row {row_number} ({row_id}): invalid verification_state "
            f"{row['verification_state']!r}"
        )

    validate_path_refs(row_number, "emacs_source", row["emacs_source"], errors)
    validate_path_refs(row_number, "implementation", row["implementation"], errors)
    validate_path_refs(
        row_number, "verification_evidence", row["verification_evidence"], errors
    )

    disposition = row["disposition"]
    state = row["verification_state"]
    implementation = row["implementation"]
    evidence = row["verification_evidence"]
    divergence = row["divergence"]
    blocked_by = row["blocked_by"]

    if disposition == "exact":
        if state not in {"automated", "manual"}:
            errors.append(
                f"row {row_number} ({row_id}): exact requires automated or "
                "approved manual verification"
            )
        if implementation == "none":
            errors.append(
                f"row {row_number} ({row_id}): exact requires an implementation"
            )
        if evidence == "none":
            errors.append(f"row {row_number} ({row_id}): exact requires evidence")
        if divergence != "none":
            errors.append(
                f"row {row_number} ({row_id}): exact must have divergence=none"
            )
        if blocked_by != "none":
            errors.append(
                f"row {row_number} ({row_id}): exact must have blocked_by=none"
            )

    if disposition == "approximation":
        if implementation == "none":
            errors.append(
                f"row {row_number} ({row_id}): approximation requires an implementation"
            )
        if divergence == "none":
            errors.append(
                f"row {row_number} ({row_id}): approximation must name its divergence"
            )

    if disposition == "gap":
        if divergence == "none":
            errors.append(
                f"row {row_number} ({row_id}): gap must describe the missing behavior"
            )
        if blocked_by == "none":
            errors.append(
                f"row {row_number} ({row_id}): gap must name blocked_by"
            )
        if state not in {"blocked", "source-only", "none"}:
            errors.append(
                f"row {row_number} ({row_id}): gap has incompatible verification_state"
            )

    if disposition == "n-a":
        if implementation != "none" or state != "n-a" or evidence != "none":
            errors.append(
                f"row {row_number} ({row_id}): n-a requires implementation=none, "
                "verification_state=n-a, and verification_evidence=none"
            )

    if disposition == "unassessed":
        if state not in {"source-only", "none"}:
            errors.append(
                f"row {row_number} ({row_id}): unassessed must be source-only or none"
            )
        if divergence != "unassessed":
            errors.append(
                f"row {row_number} ({row_id}): unassessed requires divergence=unassessed"
            )

    if state == "automated":
        refs = split_refs(evidence)
        if evidence == "none" or not any(
            ref.split("#", 1)[0].startswith("scripts/") for ref in refs
        ):
            errors.append(
                f"row {row_number} ({row_id}): automated verification requires a "
                "scripts/ evidence reference"
            )
    elif state == "manual":
        refs = split_refs(evidence)
        if evidence == "none" or not all(ref.startswith("approved:") for ref in refs):
            errors.append(
                f"row {row_number} ({row_id}): manual evidence must be explicitly "
                "approved with approved:<local-path>#<record>"
            )
    elif state == "source-only":
        if evidence == "none":
            errors.append(
                f"row {row_number} ({row_id}): source-only requires a source reference"
            )
    elif state in {"blocked", "none", "n-a"} and evidence != "none":
        errors.append(
            f"row {row_number} ({row_id}): {state} verification requires evidence=none"
        )


def main() -> int:
    errors: list[str] = []
    if not LEDGER.is_file():
        print(f"ERROR: missing ledger: {LEDGER.relative_to(ROOT)}", file=sys.stderr)
        return 1

    with LEDGER.open("r", encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream, delimiter="\t", strict=True)
        if reader.fieldnames != HEADER:
            print(
                "ERROR: ledger header mismatch\n"
                f"expected: {HEADER}\n"
                f"actual:   {reader.fieldnames}",
                file=sys.stderr,
            )
            return 1
        rows = list(reader)

    if not rows:
        errors.append("ledger has no data rows")

    ids = [row["id"] for row in rows]
    duplicate_ids = sorted(row_id for row_id, count in Counter(ids).items() if count > 1)
    if duplicate_ids:
        errors.append(f"duplicate ids: {', '.join(duplicate_ids)}")

    areas = [row["area"] for row in rows]
    missing_areas = [area for area in EXPECTED_AREAS if area not in areas]
    if missing_areas:
        errors.append(f"missing inventory areas: {', '.join(missing_areas)}")
    known_area_order = {area: index for index, area in enumerate(EXPECTED_AREAS)}
    area_positions = [known_area_order.get(area, len(EXPECTED_AREAS)) for area in areas]
    if area_positions != sorted(area_positions):
        errors.append("rows must stay grouped in inventory area order")

    for row_number, row in enumerate(rows, start=2):
        if None in row:
            errors.append(f"row {row_number}: too many columns")
            continue
        validate_row(row_number, row, errors)

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"Parity ledger validation failed with {len(errors)} error(s).", file=sys.stderr)
        return 1

    counts = Counter(row["disposition"] for row in rows)
    summary = ", ".join(f"{name}={counts[name]}" for name in sorted(counts))
    print(f"Parity ledger OK: {len(rows)} rows across {len(set(areas))} areas ({summary})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
