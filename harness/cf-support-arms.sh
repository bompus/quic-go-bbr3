#!/usr/bin/env bash
# The test Cloudflare support asked for in ticket 02376654 (2026-10-19), with a fifth arm added: one 640 MiB download per run through a
# quick tunnel, for the arms below, interleaved with the order rotated each repetition, the host gated to be quiet before
# every download.
#   stock     the official cloudflared release, QUIC
#   bbr3      cloudflared built against quic-go 432b156 with bbr3-quic-go.patch (no logging patches), QUIC
#   v064      cloudflared built against quic-go v0.64.1 with the two Cloudflare fork commits cherry-picked, QUIC (Reno)
#   v064bbr3  the v064 build with bbr3-quic-go.patch applied on top, QUIC
#   http2     the official cloudflared release, --protocol http2 (control)
# Per run it saves cloudflared's /metrics before and after the download, the edge address and location from the log, and
# for the http2 arm `ss -ti` samples once a second and a header-only packet capture of the outer tunnel traffic.
# `mtr` to each new edge address is run once, before that run's download.
#   cf-support-arms.sh <outdir> <reps> <stock-bin> <bbr3-bin> <v064-bin> <v064bbr3-bin>
# Quick tunnels land on a random edge location and cannot be pinned: restarting a tunnel to get a chosen location hit
# trycloudflare.com's rate limit (HTTP 429) after three requests. The summary therefore reports each download's location.
# REP_START=<n> resumes an interrupted run at repetition n, appending to the same <outdir>/runs.tsv.
# Needs passwordless sudo (tcpdump, mtr, kill), bun (origin.ts), curl, ss. Results: <outdir>/runs.tsv.
set -euo pipefail
export LC_ALL=C
OUT=${1:?outdir}
REPS=${2:?reps}
BIN_STOCK=${3:?stock cloudflared}
BIN_BBR3=${4:?bbr3 cloudflared}
BIN_V064=${5:?v064 cloudflared}
BIN_V064BBR3=${6:?v064bbr3 cloudflared}
MB=${MB:-640}
GAP=${GAP:-30}
H=$(cd "$(dirname "$0")" && pwd)
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
[ -x "$PS" ] || PS=
mkdir -p "$OUT/logs" "$OUT/metrics" "$OUT/ss" "$OUT/pcap" "$OUT/mtr"
[ -s "$OUT/runs.tsv" ] || : >"$OUT/runs.tsv"
OP=${ORIGIN_PORT:-8080}
bun "$H/origin.ts" "$OP" 127.0.0.1 >"$OUT/origin.log" 2>&1 &
PO=$!
sleep 1
# shellcheck disable=SC2015 # the block is meant to run when either check fails
[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$OP/ping" || true)" = 200 ] && kill -0 $PO 2>/dev/null || {
  echo "origin.ts did not start on 127.0.0.1:$OP" >&2
  kill $PO 2>/dev/null || true
  exit 1
}
PC=
PT=
SSPID=
cleanup() {
  [ -z "$PC" ] || kill "$PC" 2>/dev/null || true
  [ -z "$PT" ] || sudo -n kill "$PT" 2>/dev/null || true
  [ -z "$SSPID" ] || kill "$SSPID" 2>/dev/null || true
  kill $PO 2>/dev/null || true
}
trap cleanup EXIT

quiet() { # prints "win vm"; returns 0 when quiet (Windows <= 30%, VM <= 15%); waits up to 300 s
  local t0=$SECONDS w v a b
  while :; do
    a=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5+$6}' /proc/stat)
    sleep 3
    b=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5+$6}' /proc/stat)
    v=$(awk -v a="$a" -v b="$b" 'BEGIN{split(a,x," ");split(b,y," ");printf "%.1f",100*((y[1]-x[1])-(y[2]-x[2]))/(y[1]-x[1])}')
    if [ -n "$PS" ]; then
      w=$($PS -NoProfile -Command "(Get-Counter '\\Processor Information(_Total)\\% Processor Time' -SampleInterval 1 -MaxSamples 3).CounterSamples | ForEach-Object { \$_.CookedValue } | Measure-Object -Average | ForEach-Object { \$_.Average }" | tr -d '\r')
    else w=0; fi
    w=$(printf "%.1f" "$w")
    echo "$w $v"
    awk -v w="$w" -v v="$v" 'BEGIN{exit !(w<=30 && v<=15)}' && return 0
    [ $((SECONDS - t0)) -lt 300 ] || return 1
  done
}

run() { # arm rep
  local arm=$1 rep=$2 bin proto=quic base mp url ip loc q load res t0 t1 try=0
  case "$arm" in
    stock) bin=$BIN_STOCK ;;
    bbr3) bin=$BIN_BBR3 ;;
    v064) bin=$BIN_V064 ;;
    v064bbr3) bin=$BIN_V064BBR3 ;;
    http2)
      bin=$BIN_STOCK
      proto=http2
      ;;
  esac
  base="$OUT/logs/$arm-$rep"
  mp=$((20000 + RANDOM % 20000))
  while [ $try -lt 3 ]; do
    "$bin" tunnel --no-autoupdate --url "http://127.0.0.1:$OP" --protocol "$proto" --metrics "127.0.0.3:$mp" >"$base.cf" 2>&1 &
    PC=$!
    url=
    for _ in $(seq 60); do
      url=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$base.cf" | head -1 || true)
      [ -n "$url" ] && break
      sleep 1
    done
    [ -n "$url" ] && break
    kill "$PC" 2>/dev/null || true
    wait "$PC" 2>/dev/null || true
    PC=
    try=$((try + 1))
    echo "$arm-$rep: no tunnel URL, attempt $try, sleeping 300" >&2
    [ "$try" -ge 3 ] || sleep 300
  done
  [ -n "$url" ] || {
    echo -e "$arm\t$rep\tno-url" >>"$OUT/runs.tsv"
    return
  }
  for _ in $(seq 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url/ping" || true)" = 200 ] && break
    sleep 1
  done
  sleep 3
  ip=$(grep -o 'ip=[0-9a-f.:]*' "$base.cf" | head -1 | cut -d= -f2 || true)
  loc=$(grep -o 'location=[a-z0-9]*' "$base.cf" | head -1 | cut -d= -f2 || true)
  if [ -n "$ip" ] && [ ! -s "$OUT/mtr/$ip.txt" ]; then
    {
      echo "# ICMP"
      sudo -n mtr -r -w -n -c 20 "$ip" || true
      echo "# TCP 7844"
      sudo -n mtr -r -w -n -T -P 7844 -c 20 "$ip" || true
    } >"$OUT/mtr/$ip.txt" 2>&1
  fi
  if q=$(quiet); then load="quiet $(echo "$q" | tail -1)"; else load="busy $(echo "$q" | tail -1)"; fi
  curl -s "http://127.0.0.3:$mp/metrics" >"$OUT/metrics/$arm-$rep-before.txt" || true
  if [ "$arm" = http2 ] && [ -n "$ip" ]; then
    # shellcheck disable=SC2024 # the log file belongs to this user; only tcpdump needs root
    sudo -n tcpdump -i any -s 128 -w "$OUT/pcap/$arm-$rep.pcap" "host $ip and tcp port 7844" >"$base.tcpdump" 2>&1 &
    PT=$!
    (while :; do
      date +%s.%N
      ss -ti dst "$ip" dport = :7844
      sleep 1
    done >"$OUT/ss/$arm-$rep.txt" 2>&1) &
    SSPID=$!
    sleep 1
  fi
  t0=$(date +%s.%N)
  res=$(curl -s -o /dev/null --max-time 400 -w '%{speed_download} %{time_total} %{http_version} %{size_download} %{http_code}' "$url/blob/$MB" || true)
  [ -n "$res" ] || res="fail 0 0 0 0"
  t1=$(date +%s.%N)
  curl -s "http://127.0.0.3:$mp/metrics" >"$OUT/metrics/$arm-$rep-after.txt" || true
  if [ -n "$SSPID" ]; then
    kill "$SSPID" 2>/dev/null || true
    SSPID=
    sudo -n kill "$PT" 2>/dev/null || true
    wait "$PT" 2>/dev/null || true
    PT=
  fi
  kill "$PC" 2>/dev/null || true
  wait "$PC" 2>/dev/null || true
  PC=
  echo -e "$arm\t$rep\t$res\t$load\twall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f",b-a}')\tip=$ip\tloc=$loc\tbin=$(basename "$bin")" | tee -a "$OUT/runs.tsv"
  sleep "$GAP"
}

ARMS=(stock bbr3 v064 v064bbr3 http2)
for rep in $(seq "${REP_START:-1}" "$REPS"); do
  for i in 0 1 2 3 4; do
    run "${ARMS[$(((i + rep - 1) % 5))]}" "$rep"
  done
done
echo "finished" >>"$OUT/runs.tsv"
