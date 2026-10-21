#!/bin/bash
# peermon-monitor - poll both peermon nodes from a remote host and name the failure pattern.
#
# Usage: peermon-monitor <vm-a-url> <vm-b-url> [interval-seconds] [csv-file]
#   e.g. peermon-monitor http://10.20.1.10:8000 http://10.30.1.10:8000 5
# Needs: bash, jq, and peermonctl on PATH (or PEERMONCTL=/path/to/peermonctl).
# Writes one CSV row per poll and prints a one-line summary; Ctrl-C to stop.
set -uo pipefail

A=${1:?usage: peermon-monitor <vm-a-url> <vm-b-url> [interval] [csv]}
B=${2:?usage: peermon-monitor <vm-a-url> <vm-b-url> [interval] [csv]}
INTERVAL=${3:-5}
OUT=${4:-monitor-$(date -u +%Y%m%dT%H%M%SZ).csv}
CTL=${PEERMONCTL:-peermonctl}
TIMEOUT=${MONITOR_TIMEOUT:-3}
# how long a node must be unreachable before the peer's view is trusted
# (peer needs 3 failed checks at 5 s = ~15-17 s to declare it down)
CONFIRM=${MONITOR_CONFIRM:-20}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

command -v jq >/dev/null || { echo "jq is required (sudo apt install jq)" >&2; exit 2; }
command -v "$CTL" >/dev/null || { echo "peermonctl not found (set PEERMONCTL=/path/to/peermonctl)" >&2; exit 2; }

# prints: reach,reason,sees_peer,peer_fails,boot_id
probe() {
  local out
  out=$("$CTL" neighbor --host "$1" --json --timeout "$TIMEOUT" 2>/dev/null)
  echo "$out" | jq -r 'if .status == "down" then "down,\(.reason),-,-,-"
                       else "up,-,\(.peer_status),\(.consecutive_failures),\(.boot_id)" end' 2>/dev/null \
    | grep . || echo "down,unreachable,-,-,-"
}

verdict() {   # a_reach a_reason a_sees b_reach b_reason b_sees a_down_for b_down_for
  local ar=$1 aw=$2 as=$3 br=$4 bw=$5 bs=$6 ad=$7 bd=$8
  if [ "$ar" = up ] && [ "$br" = up ]; then
    if   [ "$as" = up ]   && [ "$bs" = up ];   then echo HEALTHY
    elif [ "$as" = down ] && [ "$bs" = down ]; then echo PARTITION
    elif [ "$as" = down ] || [ "$bs" = down ]; then echo ONE_WAY_LOSS
    else echo DETECTING; fi
  elif [ "$ar" = down ] && [ "$br" = down ]; then echo MONITOR_ISOLATED
  elif [ "$ar" = down ] && [ "$ad" -lt "$CONFIRM" ] && [ "$bs" != down ]; then echo A_UNREACHABLE_CONFIRMING
  elif [ "$br" = down ] && [ "$bd" -lt "$CONFIRM" ] && [ "$as" != down ]; then echo B_UNREACHABLE_CONFIRMING
  elif [ "$ar" = down ]; then
    case "$bs" in
      down) if [ "$aw" = refused ]; then echo APP_A_DOWN; else echo SITE_A_DOWN; fi ;;
      up)   echo MONITOR_PATH_A ;;
      *)    echo DETECTING ;;
    esac
  else
    case "$as" in
      down) if [ "$bw" = refused ]; then echo APP_B_DOWN; else echo SITE_B_DOWN; fi ;;
      up)   echo MONITOR_PATH_B ;;
      *)    echo DETECTING ;;
    esac
  fi
}

[ -s "$OUT" ] || echo "ts_utc,a_reach,a_reason,a_sees_b,a_fails,a_boot,b_reach,b_reason,b_sees_a,b_fails,b_boot,verdict" > "$OUT"
echo "polling A=$A  B=$B  every ${INTERVAL}s  ->  $OUT   (Ctrl-C to stop)"
trap 'echo; echo "stopped; results in $OUT"; rm -rf "$TMP"; exit 0' INT TERM
last=""; a_since=0; b_since=0
while :; do
  t0=$(date +%s%N)
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  probe "$A" > "$TMP/a" & probe "$B" > "$TMP/b" & wait
  IFS=, read -r ar aw as af abt < "$TMP/a"
  IFS=, read -r br bw bs bf bbt < "$TMP/b"
  now=$(date +%s)
  if [ "$ar" = down ]; then [ $a_since -eq 0 ] && a_since=$now; else a_since=0; fi
  if [ "$br" = down ]; then [ $b_since -eq 0 ] && b_since=$now; else b_since=0; fi
  ad=$(( a_since ? now - a_since : 0 )); bd=$(( b_since ? now - b_since : 0 ))
  v=$(verdict "$ar" "$aw" "$as" "$br" "$bw" "$bs" "$ad" "$bd")
  echo "$ts,$ar,$aw,$as,$af,$abt,$br,$bw,$bs,$bf,$bbt,$v" >> "$OUT"
  mark=""; [ "$v" != "$last" ] && mark="   <-- changed"
  printf '%s  A:%-4s %-11s sees B %-7s | B:%-4s %-11s sees A %-7s | %s%s\n' \
    "${ts:11:12}" "$ar" "$aw" "$as" "$br" "$bw" "$bs" "$v" "$mark"
  last=$v
  el=$(( ($(date +%s%N) - t0) / 1000000 ))
  sl=$(( INTERVAL * 1000 - el )); [ $sl -gt 0 ] && sleep "$(awk "BEGIN{print $sl/1000}")"
done
