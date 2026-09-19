"""Summarize complete pipeline-samples.lisp captures without histogram rounding.

Usage: python3 scripts/bench/e2e/analyze-pipeline-samples.py capture.csv [...]
Percentiles use nearest rank. Units and resolution are those of the pipeline
clock; these durations end at core redisplay, not physical presentation.
"""

import argparse
import csv
import json
from pathlib import Path


STAGES = ("queue-wait", "command", "redisplay", "keystroke")


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
    if not rows or rows.pop(0) != ["stage", "us"]:
        raise ValueError("expected stage,us header")
    if (int(metadata["recorded"]) != len(rows)
            or int(metadata["capacity"]) < len(rows)
            or int(metadata["dropped"]) != 0
            or metadata["recorder-replaced"] != "nil"):
        raise ValueError("capture was truncated, replaced, or has inconsistent counts")
    if not rows:
        raise ValueError("capture contains no samples")
    stages = {stage: [] for stage in STAGES}
    for stage, value in rows:
        duration = int(value)
        if stage not in stages or duration < 0:
            raise ValueError(f"invalid sample: {stage},{value}")
        stages[stage].append(duration)
    result = {}
    for stage, values in stages.items():
        if not values:
            continue
        values.sort()
        count = len(values)
        result[stage] = {
            "count": count,
            "min_us": values[0],
            "p50_us": values[(count * 50 + 99) // 100 - 1],
            "p95_us": values[(count * 95 + 99) // 100 - 1],
            "max_us": values[-1],
        }
    return {"file": str(path), "stages": result}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", type=Path, nargs="+")
    args = parser.parse_args()
    try:
        results = [summarize(path) for path in args.captures]
    except (OSError, ValueError, KeyError) as error:
        parser.error(str(error))
    print(json.dumps(results, indent=2))
