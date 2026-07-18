#!/usr/bin/env node
// analyze-soak.mjs -- soak leak detector (SPEC-PERF PF-8).
//
// Usage: node analyze-soak.mjs --csv <rss.csv> --dump <metrics.json>
//                              [--threshold-mb-min <n>] [--min-points <n>]
//
// Reads TWO independent memory-growth signals and flags a leak only when BOTH
// grow, so the verdict does not hinge on either source alone (SPEC-PERF PF-8:
// "RSS growth AND dynamic-usage growth"):
//
//   * RSS growth -- from the external CSV (`t_seconds,rss_bytes'), sampled every
//     10 s from /proc/<pid>/status by soak.sh, INDEPENDENT of any in-image
//     state.  RSS is a high-water-ish measure that SBCL periodically munmaps
//     back to the OS after full GCs, so it sawtooths with big downward jumps;
//     a least-squares slope over a short window is dominated by whichever munmap
//     falls in it (measured: a clean run's second-half LS slope swung to
//     -47 MB/min).  We therefore use a ROBUST rate: the MEDIAN of the second
//     half minus the MEDIAN of the first half, over their time separation --
//     outlier munmap dips cannot flip it.
//
//   * dynamic-usage growth -- from the metrics dump's `heap-samples' ring (the
//     in-image `sb-kernel:dynamic-usage', idle-timer sampled).  Raw
//     dynamic-usage SAWTOOTHS with the GC cycle (±hundreds of MB between an
//     allocation peak and a post-GC trough), so a least-squares fit over raw
//     samples catches whichever phase the sampling lands on -- useless.  The
//     RETAINED memory is the LOWER ENVELOPE (the post-GC troughs): flat for a
//     healthy steady state, rising for a genuine leak.  We therefore compare the
//     low-percentile FLOOR of the first half vs the second half and report the
//     floor's growth rate.  (Measured on this editor: a clean editing soak holds
//     a ~305 MB dynamic-usage floor throughout; an injected 1 MB/idle-tick leak
//     lifts it steadily.)
//
// Threshold rationale (default 1 MB/min, BOTH must exceed):
//   A real leak retains memory monotonically -- the dynamic-usage floor climbs
//   past every GC and RSS follows.  A healthy editor's second-half floor is flat
//   (slope ~0) even though its raw dynamic-usage sawtooths and its RSS may drift
//   up a little from arena growth / fragmentation.  Requiring BOTH the RSS slope
//   AND the dynamic-usage FLOOR rate to exceed 1 MB/min rejects the two common
//   false positives -- RSS warm-up drift alone, and a dynamic-usage sawtooth
//   alone.  1 MB/min over a 15-min second half is 15 MB, well above sampling
//   noise yet far below any genuine leak (the self-test injects >10x this).
//   Revisable with a ledger entry (PF-8).
//
// Exit codes:  0 CLEAN   1 LEAK SUSPECT   2 INSUFFICIENT DATA

"use strict";

import { readFileSync } from "node:fs";

function die(msg) {
  process.stderr.write("analyze-soak: " + msg + "\n");
  process.exit(2);
}

// --- args -------------------------------------------------------------------
const args = process.argv.slice(2);
let csvPath = null, dumpPath = null;
let thresholdMbMin = 1, minPoints = 4;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === "--csv") csvPath = args[++i];
  else if (a === "--dump") dumpPath = args[++i];
  else if (a === "--threshold-mb-min") thresholdMbMin = Number(args[++i]);
  else if (a === "--min-points") minPoints = Number(args[++i]);
  else die("unknown argument: " + a);
}
if (!csvPath) die("missing --csv");
if (!dumpPath) die("missing --dump");

const MB = 1024 * 1024;

// --- helpers ----------------------------------------------------------------
//
// The "floor" of a half is the MINIMUM dynamic-usage observed in it.  A
// dynamic-usage reading can never fall below the live set, so the minimum is
// the closest sampled approximation to retained memory (a deep post-GC trough)
// and can never spuriously undershoot -- it can only be too HIGH if no deep GC
// happened to be sampled, which biases toward NOT flagging (conservative).  A
// higher percentile misses sparse troughs (measured: it read 342 MB while the
// true 306 MB trough sat two samples lower), so min it is.

function mean(values) {
  if (values.length === 0) return null;
  return values.reduce((a, b) => a + b, 0) / values.length;
}

function median(values) {
  if (values.length === 0) return null;
  const s = values.slice().sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

// Split {t,v} points into first / second half at the t-range midpoint.
function halves(points) {
  const sorted = points.slice().sort((a, b) => a.t - b.t);
  if (sorted.length === 0) return { first: [], second: [], sorted };
  const mid = (sorted[0].t + sorted[sorted.length - 1].t) / 2;
  return {
    first: sorted.filter(p => p.t < mid),
    second: sorted.filter(p => p.t >= mid),
    sorted,
  };
}

// --- RSS: robust median-of-halves growth rate (MB/min) ----------------------
function analyzeRss(points) {
  const { first, second, sorted } = halves(points);
  let rateMbMin = null, med1 = null, med2 = null;
  if (first.length >= minPoints && second.length >= minPoints) {
    med1 = median(first.map(p => p.v));
    med2 = median(second.map(p => p.v));
    const dtMin = (mean(second.map(p => p.t)) - mean(first.map(p => p.t))) / 60;
    if (dtMin > 0) rateMbMin = (med2 - med1) / dtMin / MB;
  }
  return {
    nTotal: sorted.length,
    nFirst: first.length,
    nSecond: second.length,
    med1Bytes: med1,
    med2Bytes: med2,
    startBytes: sorted.length ? sorted[0].v : 0,
    endBytes: sorted.length ? sorted[sorted.length - 1].v : 0,
    rateMbMin,
  };
}

// --- dynamic-usage: floor (min-per-half) growth rate across halves (MB/min) --
function analyzeFloor(points) {
  const { first, second, sorted } = halves(points);
  let rateMbMin = null, floor1 = null, floor2 = null;
  if (first.length >= minPoints && second.length >= minPoints) {
    floor1 = Math.min(...first.map(p => p.v));
    floor2 = Math.min(...second.map(p => p.v));
    const dtMin = (mean(second.map(p => p.t)) - mean(first.map(p => p.t))) / 60;
    if (dtMin > 0) rateMbMin = (floor2 - floor1) / dtMin / MB;
  }
  return {
    nTotal: sorted.length,
    nFirst: first.length,
    nSecond: second.length,
    floor1Bytes: floor1,
    floor2Bytes: floor2,
    startBytes: sorted.length ? sorted[0].v : 0,
    endBytes: sorted.length ? sorted[sorted.length - 1].v : 0,
    rateMbMin,
  };
}

// --- read the external RSS CSV ---------------------------------------------
let rssPoints = [];
try {
  for (const line of readFileSync(csvPath, "utf8").split("\n")) {
    const s = line.trim();
    if (!s || s.startsWith("t_seconds")) continue;
    const [t, rss] = s.split(",");
    const tn = Number(t), rn = Number(rss);
    if (!Number.isNaN(tn) && !Number.isNaN(rn)) rssPoints.push({ t: tn, v: rn });
  }
} catch (e) {
  die("cannot read CSV " + csvPath + ": " + e.message);
}

// --- read the in-image dynamic-usage samples + GC pause p99 -----------------
let duPoints = [];
let gcPauseP99Us = 0, gcCount = 0;
try {
  const doc = JSON.parse(readFileSync(dumpPath, "utf8"));
  const samples = Array.isArray(doc["heap-samples"]) ? doc["heap-samples"] : [];
  for (const s of samples) {
    const tn = Number(s.t), du = Number(s["dynamic-usage"]);
    if (!Number.isNaN(tn) && !Number.isNaN(du)) duPoints.push({ t: tn, v: du });
  }
  if (doc.gc && doc.gc["pause-us"] && typeof doc.gc["pause-us"].p99 === "number")
    gcPauseP99Us = doc.gc["pause-us"].p99;
  if (doc.gc && typeof doc.gc.count === "number") gcCount = doc.gc.count;
} catch (e) {
  die("cannot read/parse dump " + dumpPath + ": " + e.message);
}

const rss = analyzeRss(rssPoints);
const du = analyzeFloor(duPoints);

// --- verdict ----------------------------------------------------------------
let verdict, exitCode;
const insufficient =
  rss.nFirst < minPoints || rss.nSecond < minPoints || rss.rateMbMin === null ||
  du.nFirst < minPoints || du.nSecond < minPoints || du.rateMbMin === null;

if (insufficient) {
  verdict = "INSUFFICIENT DATA";
  exitCode = 2;
} else if (rss.rateMbMin > thresholdMbMin && du.rateMbMin > thresholdMbMin) {
  verdict = "LEAK SUSPECT";
  exitCode = 1;
} else {
  verdict = "CLEAN";
  exitCode = 0;
}

// --- report -----------------------------------------------------------------
const f2 = x => (x === null || x === undefined ? "n/a" : x.toFixed(2));
const mb = b => (b === null || b === undefined ? "n/a" : (b / MB).toFixed(1));
const out = process.stdout;
out.write("Soak leak analysis (SPEC-PERF PF-8)\n");
out.write("===================================\n");
out.write(`  RSS  (external /proc): n=${rss.nTotal} (1st=${rss.nFirst} 2nd=${rss.nSecond})  ` +
          `median ${mb(rss.med1Bytes)}MB -> ${mb(rss.med2Bytes)}MB  ` +
          `rate=${f2(rss.rateMbMin)} MB/min\n`);
out.write(`  DU floor (in-image):   n=${du.nTotal} (1st=${du.nFirst} 2nd=${du.nSecond})  ` +
          `floor ${mb(du.floor1Bytes)}MB -> ${mb(du.floor2Bytes)}MB  ` +
          `rate=${f2(du.rateMbMin)} MB/min\n`);
out.write(`  GC: count=${gcCount}  pause p99=${(gcPauseP99Us / 1000).toFixed(1)} ms\n`);
out.write(`  threshold: ${thresholdMbMin} MB/min (RSS rate AND DU-floor rate), ` +
          `min ${minPoints} pts/half\n`);
out.write(`VERDICT: ${verdict}\n`);

// Machine-readable tail (soak.sh / the ledger grep these).
out.write(`RSS_RATE_MB_MIN=${f2(rss.rateMbMin)}\n`);
out.write(`DU_FLOOR_RATE_MB_MIN=${f2(du.rateMbMin)}\n`);
out.write(`RSS_START_BYTES=${rss.startBytes}\n`);
out.write(`RSS_END_BYTES=${rss.endBytes}\n`);
out.write(`DU_FLOOR1_BYTES=${du.floor1Bytes === null ? "n/a" : du.floor1Bytes}\n`);
out.write(`DU_FLOOR2_BYTES=${du.floor2Bytes === null ? "n/a" : du.floor2Bytes}\n`);
out.write(`DU_START_BYTES=${du.startBytes}\n`);
out.write(`DU_END_BYTES=${du.endBytes}\n`);
out.write(`GC_COUNT=${gcCount}\n`);
out.write(`GC_PAUSE_P99_US=${gcPauseP99Us}\n`);
out.write(`RSS_SAMPLES=${rss.nTotal}\n`);
out.write(`DU_SAMPLES=${du.nTotal}\n`);
out.write(`VERDICT=${verdict}\n`);

process.exit(exitCode);
