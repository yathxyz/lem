"""Summarize complete pipeline-samples.lisp captures without histogram rounding.

Usage: python3 scripts/bench/e2e/analyze-pipeline-samples.py capture.csv [...]
Percentiles use nearest rank. Units and resolution are those of the pipeline
clock; these durations end at core redisplay, not physical presentation.
Optional resource counters are process-wide. Their command-to-redisplay deltas
include recorder overhead and other threads; GC CPU time is not a wall pause.
"""

import argparse
import csv
import json
from pathlib import Path


STAGES = ("queue-wait", "command", "redisplay", "keystroke")


def distribution(values, suffix="_us"):
    if not values:
        return {"count": 0}
    values = sorted(values)
    count = len(values)
    return {
        "count": count,
        "min" + suffix: values[0],
        "p50" + suffix: values[(count * 50 + 99) // 100 - 1],
        "p95" + suffix: values[(count * 95 + 99) // 100 - 1],
        "max" + suffix: values[-1],
    }


def summarize(path):
    metadata = {}
    data = []
    for line in path.read_text().splitlines():
        if line.startswith("# "):
            key, value = line[2:].split(",", 1)
            metadata[key] = value
        else:
            data.append(line)
    rows = list(csv.reader(data))
    header = rows.pop(0) if rows else []
    resources = header == ["stage", "us", "cpu", "gc_cpu", "consed"]
    if header != ["stage", "us"] and not resources:
        raise ValueError("expected stage,us header, optionally with cpu,gc_cpu,consed")
    units = int(metadata["cpu-units-per-second"]) if resources else 1
    if units <= 0:
        raise ValueError("CPU clock units must be positive")
    if (int(metadata["recorded"]) != len(rows)
            or int(metadata["capacity"]) < len(rows)
            or int(metadata["dropped"]) != 0
            or metadata["recorder-replaced"] != "nil"):
        raise ValueError("capture was truncated, replaced, or has inconsistent counts")
    if not rows:
        raise ValueError("capture contains no samples")
    stages = {stage: [] for stage in STAGES}
    previous_counters = None
    command_counters = None
    redraws = []
    unpaired = 0
    for row in rows:
        if len(row) != len(header):
            raise ValueError("sample column count does not match header")
        stage, value = row[:2]
        duration = int(value)
        if stage not in stages or duration < 0:
            raise ValueError(f"invalid sample: {stage},{value}")
        stages[stage].append(duration)
        if not resources:
            continue
        counters = tuple(map(int, row[2:]))
        if (any(value < 0 for value in counters)
                or (previous_counters is not None
                    and any(now < old for now, old in zip(counters, previous_counters)))):
            raise ValueError("resource counters must be nonnegative and monotonic")
        previous_counters = counters
        if stage == "queue-wait":
            command_counters = None
        elif stage == "command":
            command_counters = counters
        elif stage == "redisplay":
            if command_counters is None:
                unpaired += 1
            else:
                cpu, gc_cpu, consed = [now - old for now, old in zip(counters, command_counters)]
                redraws.append({
                    "paint": len(stages["redisplay"]),
                    "wall_us": duration,
                    "cpu_us": cpu * 1000000 / units,
                    "gc_cpu_us": gc_cpu * 1000000 / units,
                    "allocated_bytes": consed,
                })
            command_counters = None
    result = {"file": str(path), "stages": {
        stage: distribution(values) for stage, values in stages.items() if values
    }}
    if resources:
        groups = {}
        for name, with_gc in (("with_gc", True), ("without_gc", False)):
            selected = [r for r in redraws if (r["gc_cpu_us"] > 0) == with_gc]
            groups[name] = {
                key: distribution(
                    [r[key] for r in selected],
                    "_bytes" if key == "allocated_bytes" else "_us",
                )
                for key in ("wall_us", "cpu_us", "gc_cpu_us", "allocated_bytes")
            }
        result["redisplay_resources"] = {
            "paired": len(redraws),
            "unpaired": unpaired,
            "groups": groups,
            "slowest": sorted(redraws, key=lambda r: r["wall_us"], reverse=True)[:10],
        }
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", type=Path, nargs="+")
    args = parser.parse_args()
    try:
        results = [summarize(path) for path in args.captures]
    except (OSError, ValueError, KeyError) as error:
        parser.error(str(error))
    print(json.dumps(results, indent=2))
