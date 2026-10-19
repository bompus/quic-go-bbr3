# quic-go-bbr3

A BBRv3 congestion controller for [quic-go](https://github.com/quic-go/quic-go), and the
measurements that came with it. I wrote it to test whether the sender explains why
`cloudflared` over QUIC downloads at about half the rate of `cloudflared` over HTTP/2 through
a quick tunnel.

This is an experiment, not a supported library. It is not wired to any setting: the patch
replaces the Reno sender quic-go builds today.

## What is here

| Path | What it is |
| --- | --- |
| `bbr3-quic-go.patch` | The sender (`internal/congestion/bbr3_sender.go`, about 1,350 lines), a simulation test, and a 6-line change to `internal/ackhandler/sent_packet_handler.go` that swaps `NewCubicSender(..., true /* use Reno */)` for `NewBBR3Sender`. Applies to quic-go v0.64.1 and to upstream commit `432b156` |
| quic-go branch [`bbr3-v0.64.1`](https://github.com/bompus/quic-go/tree/bbr3-v0.64.1) | The same patch as one commit on top of quic-go v0.64.1 and the two commits Cloudflare's fork holds beyond v0.59.1 (`729b8673` custom max UDP payload size, `5d6220aa` BoringSSL). This is the tree the `cloudflared` binaries below were built from |
| `harness/` | The test script, its summary script and the origin server it downloads from |
| `data/` | The raw results: `runs-four-arm.tsv` (first run), `runs-five-arm.tsv` (second run) and `lab-runs.tsv` (lab matrix) |

## What it is a port of

Google's `net/ipv4/tcp_bbr3.c` on branch `bbr-v3-2026-09-16-01` of
[google/bbr](https://github.com/google/bbr) (`GPL-2.0 OR BSD-3-Clause`). The state machine,
the bandwidth and in-flight model, the loss response and the constants follow the C source
function for function (start-up gain 2.77, drain 0.5, probe-down 0.91, loss threshold 2%,
beta 0.3, headroom 15%, 5 s probe-RTT interval, 10 s minimum-RTT window, 200 ms probe-RTT).
Quantities are in bytes. Each delivery-rate sample is built from per-packet send state, as
`tcp_rate.c` does, and the model runs once per ACK frame.

Not ported: the fast path, fast ACK mode, the kernel's timeout state (quic-go never reports
a retransmission timeout as one), the tail-loss-probe recovery event and ECN (the source has
none). quic-go gives no application-limited signal, so a flow counts as application limited
from the moment nothing is in flight until it delivers new data. The comment at the top of
the file lists these differences.

The port is licensed `BSD-3-Clause`; see `LICENSE`.

## Build it into cloudflared

This is how the binaries in the results were built.

1. Check out `cloudflared` at commit `bf4f502` (2026-10-08, "TUN-10933: Bump go to 1.27").
   Build with Go 1.27.2 on Linux amd64.
2. Check out the quic-go branch: `git clone -b bbr3-v0.64.1 https://github.com/bompus/quic-go`.
3. In `cloudflared`'s `go.mod`, replace the line that points at Cloudflare's fork with
   `replace github.com/quic-go/quic-go => /path/to/quic-go`.
4. Build `cloudflared` as usual.

To apply the patch to another tree yourself: `git apply bbr3-quic-go.patch`.

## Results

Eight repetitions of each arm, one 640 MiB download each, through a quick tunnel started for
that download (one connection), arm order rotated each repetition, the host quiet before each
download. Stock is the official `cloudflared` 2026.10.0. The ratio is to the HTTP/2 download
of the same repetition. All numbers are from `data/`.

Second run (five arms, 2026-10-19):

| Arm | Mean MB/s | Std dev | Ratio to HTTP/2, mean (median) | HTTP/2 ahead |
| --- | --- | --- | --- | --- |
| Stock QUIC | 36.6 | 17.0 | 0.46 (0.45) | 8 of 8 |
| BBRv3 on quic-go `432b156` | 60.7 | 6.6 | 0.81 (0.74) | 7 of 8 |
| quic-go v0.64.1, Reno | 44.7 | 9.7 | 0.63 (0.50) | 7 of 8 |
| BBRv3 on quic-go v0.64.1 | 66.8 | 4.6 | 0.89 (0.81) | 7 of 8 |
| HTTP/2 | 78.5 | 14.7 | baseline | |

Lab: a 600 Mbit/s path with 28 ms round trip and `fq_codel`, 8-second sends, three runs per
cell, mean Mbit/s:

| Sender | 0% added loss | 0.01% | 0.1% |
| --- | --- | --- | --- |
| Linux TCP (BBR) | 471 | 456 | 387 |
| quic-go v0.64.1, Reno | 515 | 383 | 113 |
| quic-go v0.64.1 with BBRv3 | 540 | 521 | 532 |
| quic-go `432b156` with BBRv3 | 549 | 548 | 539 |

What this supports and what it does not:

- A BBRv3 sender is the only change I tested that moved QUIC reliably toward HTTP/2. It does
  not close the gap: HTTP/2 was ahead in most paired downloads.
- v0.64.1 with Reno is **not** shown to beat stock. A quick tunnel lands on a random edge
  location that cannot be chosen, and v0.64.1 landed on `sea01` in 7 of its 16 downloads
  (both runs) where stock never did. Over the locations both reached the difference is
  +0.3 MB/s, resting on single downloads.
- BBRv3 on v0.64.1 against BBRv3 on `432b156` (6.1 MB/s apart, standard error about 2.8) is
  suggestive, not established.
- One slow HTTP/2 download (repetition 3, 43.6 MB/s) lifts the mean ratios; the medians are
  the safer reading.
- The host's own TCP sender is BBR, so the HTTP/2 control used BBR while the QUIC arms
  without this patch used Reno. HTTP/2 under Cubic was not measured.
- A server restart and a host restart happened partway through the second run (after the
  first 20 downloads). Settings and binaries were unchanged.
- One host, one network, eight downloads per arm.

## Run the harness

```
harness/cf-support-arms.sh <outdir> <reps> <stock-bin> <bbr3-bin> <v064-bin> <v064bbr3-bin>
bun harness/cf-support-summary.ts <outdir>
```

It needs `bun`, `curl`, `ss`, passwordless `sudo` for `tcpdump` and `mtr`, and the
`cloudflared` binaries. `origin.ts` must sit next to the script. The summary script reads
`<outdir>/runs.tsv`, so to re-summarise the files in `data/` copy one into a directory under
that name (the counter table also needs the `metrics/` captures, which are not in this
repository). Per download it saves
`cloudflared`'s `/metrics` before and after, the edge address and location, and for the
HTTP/2 arm `ss -ti` samples and a header-only packet capture. The first lines of the script
describe the arms, and the script has a quiet-host gate that assumes a Windows host under
WSL (it skips the Windows check elsewhere).
