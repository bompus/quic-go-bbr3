// Summarises one or more cf-support-arms.sh runs: per-arm speed, paired ratio to the HTTP/2 download of the same
// repetition, speed by edge location, and the QUIC loss and acknowledgement counters from the metrics scraped before
// and after each download.
//   bun cf-support-summary.ts <outdir> [<outdir> ...]
import { readFileSync } from "node:fs";

const dirs = process.argv.slice(2);
if (!dirs.length) {
  throw new Error("usage: bun cf-support-summary.ts <outdir> [<outdir> ...]");
}

type Run = {
  dir: string;
  pair: string;
  arm: string;
  rep: number;
  mbps: number;
  quiet: boolean;
  loc: string;
};
const runs: Run[] = [];
dirs.forEach((dir, di) => {
  for (const line of readFileSync(`${dir}/runs.tsv`, "utf8").split("\n")) {
    const f = line.split("\t");
    if (line === "" || line === "finished") {
      continue;
    }
    if (f.length < 8) {
      throw new Error(`${dir}/runs.tsv: incomplete row: ${line}`);
    }
    const [arm = "", rep = "", result = "", gate = ""] = f;
    const parts = result.split(" ");
    const speed = parts[0] ?? "";
    const code = parts[4] ?? "";
    if (code !== "200") {
      throw new Error(
        `${dir}/runs.tsv: ${arm} repetition ${rep} did not finish with HTTP 200 (${result})`,
      );
    }
    const loc = f[6] ?? "";
    runs.push({
      dir,
      pair: `${di}:${rep}`,
      arm,
      rep: Number(rep),
      mbps: Number(speed) / 1e6,
      quiet: gate.startsWith("quiet"),
      loc: loc.replace("loc=", ""),
    });
  }
});

const mean = (a: number[]) => a.reduce((s, x) => s + x, 0) / a.length;
const sd = (a: number[]) =>
  a.length < 2 ? 0 : Math.sqrt(a.reduce((s, x) => s + (x - mean(a)) ** 2, 0) / (a.length - 1));
const median = (a: number[]) => {
  const s = [...a].sort((x, y) => x - y);
  return s.length % 2 ? s[(s.length - 1) / 2]! : (s[s.length / 2 - 1]! + s[s.length / 2]!) / 2;
};
const f1 = (x: number) => x.toFixed(1);
const f2 = (x: number) => x.toFixed(2);

const arms = ["stock", "bbr3", "v064", "v064bbr3", "http2"].filter((a) =>
  runs.some((r) => r.arm === a),
);
const byArm = (a: string) => runs.filter((r) => r.arm === a);
const h2 = new Map(byArm("http2").map((r) => [r.pair, r]));

console.log(
  "| Arm | Downloads | Mean MB/s | Std dev | Min | Max | Ratio to same-repetition HTTP/2, mean | median | HTTP/2 ahead |",
);
console.log("| --- | --- | --- | --- | --- | --- | --- | --- | --- |");
for (const a of arms) {
  const rs = byArm(a);
  if (!rs.length) {
    continue;
  }
  const v = rs.map((r) => r.mbps);
  const ratios = rs.filter((r) => h2.has(r.pair)).map((r) => r.mbps / h2.get(r.pair)!.mbps);
  const base = a === "http2" ? "baseline" : f2(mean(ratios));
  const med = a === "http2" ? "" : f2(median(ratios));
  const ahead = a === "http2" ? "" : `${ratios.filter((x) => x < 1).length} of ${ratios.length}`;
  console.log(
    `| ${a} | ${rs.length} | ${f1(mean(v))} | ${f1(sd(v))} | ${f1(Math.min(...v))} | ${f1(Math.max(...v))} | ${base} | ${med} | ${ahead} |`,
  );
}

console.log("\nMean MB/s by edge location (downloads in brackets):\n");
const locs = [...new Set(runs.map((r) => r.loc))].sort();
console.log(`| Arm | ${locs.join(" | ")} |`);
console.log(`| --- | ${locs.map(() => "---").join(" | ")} |`);
for (const a of arms) {
  const cell = (l: string) => {
    const v = runs.filter((r) => r.arm === a && r.loc === l).map((r) => r.mbps);
    return v.length ? `${f1(mean(v))} [${v.length}]` : "-";
  };
  console.log(`| ${a} | ${locs.map(cell).join(" | ")} |`);
}

console.log("\nBy repetition (MB/s, edge location):\n");
console.log(`| Run:rep | ${arms.join(" | ")} |`);
console.log(`| --- | ${arms.map(() => "---").join(" | ")} |`);
for (const pair of [...new Set(runs.map((r) => r.pair))]) {
  const cell = (a: string) => {
    const r = runs.find((x) => x.arm === a && x.pair === pair);
    return r ? `${f1(r.mbps)} (${r.loc})` : "-";
  };
  console.log(`| ${pair} | ${arms.map(cell).join(" | ")} |`);
}

// Counters: sum a metric family over its series.
function scrape(path: string) {
  const out = new Map<string, number>();
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line.startsWith("quic_client_")) {
      continue;
    }
    const m = line.match(/^(quic_client_\w+)(\{[^}]*\})?\s+(\S+)$/);
    if (m) {
      out.set(m[1] + (m[2] ?? ""), Number(m[3]));
    }
  }
  return out;
}
const sum = (m: Map<string, number>, re: RegExp) =>
  [...m].filter(([k]) => re.test(k)).reduce((s, [, v]) => s + v, 0);

console.log("\nQUIC counters per download (after minus before):\n");
console.log(
  "| Arm | Downloads | Lost, reordering threshold | Lost, time threshold | Lost as % of packets sent (approx.) | Acks received | Packets per ack received (approx.) | Packet-too-big drops |",
);
console.log("| --- | --- | --- | --- | --- | --- | --- | --- |");
for (const a of arms.filter((x) => x !== "http2")) {
  const rows: number[][] = [];
  for (const r of byArm(a)) {
    try {
      const b = scrape(`${r.dir}/metrics/${a}-${r.rep}-before.txt`);
      const e = scrape(`${r.dir}/metrics/${a}-${r.rep}-after.txt`);
      const d = (re: RegExp) => sum(e, re) - sum(b, re);
      const mtu = [...e].find(([k]) => k.startsWith("quic_client_mtu"))?.[1] || 1344;
      const pkts = d(/^quic_client_sent_bytes/) / mtu;
      const lr = d(/reordering_threshold/);
      const lt = d(/time_threshold/);
      const acks = d(/received_frames\{[^}]*Ack/);
      rows.push([lr, lt, (100 * (lr + lt)) / pkts, acks, pkts / acks, d(/packet_too_big_dropped/)]);
    } catch {
      // metrics endpoint missed on this download
    }
  }
  if (!rows.length) {
    continue;
  }
  const col = (i: number) => mean(rows.map((r) => r[i] ?? 0));
  console.log(
    `| ${a} | ${rows.length} | ${f1(col(0))} | ${f1(col(1))} | ${f2(col(2))} | ${f1(col(3))} | ${f1(col(4))} | ${f1(col(5))} |`,
  );
}
console.log(`\nDownloads gated quiet: ${runs.filter((r) => r.quiet).length} of ${runs.length}.`);
