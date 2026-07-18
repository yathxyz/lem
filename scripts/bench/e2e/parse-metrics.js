#!/usr/bin/env node
// parse-metrics.js -- extract PF-2 stage percentiles from a T0 metrics dump
// (SPEC-PERF PF-7).  jq is not available in this environment; node is.
//
// Usage: node parse-metrics.js <metrics.json>
//
// Prints shell-safe `key=value` lines (microseconds for latencies) covering
// the four pipeline stages the T3 keystroke harness gates and trends:
//
//   keystroke_{count,p50_us,p95_us}   end-to-end t4-t1 (the keystroke-to-paint
//                                     proxy; p95 is the hard-gated budget metric)
//   queuewait_{count,p50_us,p95_us}   t2-t1 (its count == events wrapped by the
//                                     ncurses pipeline -> the wrapping proof)
//   redisplay_{count,p50_us,p95_us}   t4-t3
//   command_{count,p50_us,p95_us}     t3-t2, merged over every per-command
//                                     histogram + the overflow bucket
//
// The per-stage histograms already carry p50/p95 (log2-bucket estimates) in the
// dump, so those are read directly.  The command stage is split per command
// name in the dump, so its buckets are merged here and the percentile is
// recomputed with the same log2 upper-edge estimator `histogram-percentile'
// uses in src/metrics.lisp (so the number matches what metrics-report shows).

"use strict";

const fs = require("fs");

function die(msg) {
  process.stderr.write("parse-metrics: " + msg + "\n");
  process.exit(1);
}

const path = process.argv[2];
if (!path) die("usage: parse-metrics.js <metrics.json>");

let doc;
try {
  doc = JSON.parse(fs.readFileSync(path, "utf8"));
} catch (e) {
  die("cannot read/parse " + path + ": " + e.message);
}

const latency = doc.latency || {};

// Upper microsecond edge of log2 bucket INDEX -- mirrors
// histogram-bucket-upper-edge: bucket 0 holds the value 0, bucket k (k>=1)
// covers [2^(k-1), 2^k-1] and reports 2^k.
function upperEdge(index) {
  return index === 0 ? 0 : Math.pow(2, index);
}

// Percentile from a raw bucket-count array, replicating
// histogram-percentile (nearest-rank on the cumulative count, returning the
// crossing bucket's upper edge).
function percentileFromBuckets(buckets, fraction) {
  let total = 0;
  for (const c of buckets) total += c;
  if (total === 0) return 0;
  const target = Math.ceil(fraction * total);
  let cumulative = 0;
  for (let i = 0; i < buckets.length; i++) {
    cumulative += buckets[i];
    if (cumulative >= target) return upperEdge(i);
  }
  return upperEdge(buckets.length - 1);
}

function emitStage(prefix, hist) {
  const h = hist || {};
  const count = h.count || 0;
  const p50 = h.p50 || 0;
  const p95 = h.p95 || 0;
  process.stdout.write(prefix + "_count=" + count + "\n");
  process.stdout.write(prefix + "_p50_us=" + p50 + "\n");
  process.stdout.write(prefix + "_p95_us=" + p95 + "\n");
}

emitStage("keystroke", latency["keystroke-us"]);
emitStage("queuewait", latency["queue-wait-us"]);
emitStage("redisplay", latency["redisplay-us"]);

// Merge every per-command histogram and the overflow bucket into one command
// stage histogram, then estimate its percentiles.
const commands = Array.isArray(doc.commands) ? doc.commands : [];
let nBuckets = 0;
for (const c of commands) {
  if (Array.isArray(c.buckets)) nBuckets = Math.max(nBuckets, c.buckets.length);
}
if (doc["command-overflow"] && Array.isArray(doc["command-overflow"].buckets)) {
  nBuckets = Math.max(nBuckets, doc["command-overflow"].buckets.length);
}
const merged = new Array(nBuckets).fill(0);
let cmdCount = 0;
function foldIn(hist) {
  if (!hist) return;
  cmdCount += hist.count || 0;
  if (Array.isArray(hist.buckets)) {
    for (let i = 0; i < hist.buckets.length; i++) merged[i] += hist.buckets[i];
  }
}
for (const c of commands) foldIn(c);
foldIn(doc["command-overflow"]);

process.stdout.write("command_count=" + cmdCount + "\n");
process.stdout.write("command_p50_us=" + percentileFromBuckets(merged, 0.5) + "\n");
process.stdout.write("command_p95_us=" + percentileFromBuckets(merged, 0.95) + "\n");
