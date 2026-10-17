#!/usr/bin/env bash
# check-gpu-clocks.sh — 在真实解码负载下采样三台 GPU 的 SM 时钟，识别「507 MHz 锁死」。
#
# 背景：2026-10-18 head 在 94% 利用率下恒 507 MHz（同 workload 的 node3 为 2405 MHz），
#       表现是单流吞吐只有参考值 ~50%，而 nvidia-smi 的节流标志全是 Not Active。
#       该状态 -lgc / -rgc 都覆盖不了，只能断电 30–60 s（见 docs/PITFALLS.md 第 28 行）。
#
# 用法（在 head 上跑）：
#   ./check-gpu-clocks.sh                 # 默认 http://127.0.0.1:8888，采样 6 s
#   ./check-gpu-clocks.sh URL 10          # 自定义服务地址与采样时长
#   ./check-gpu-clocks.sh --idle 6        # 不发请求，只看空闲时钟
#
# 判据：负载下 util ≥ 50% 且 SM 中位时钟 < 1200 MHz ⇒ 打 ✗（锁死/未升频）。
set -uo pipefail
cd "$(dirname "$0")" || exit 1
[ -f .env ] && { set -a; . ./.env; set +a; }

MODE=load
if [ "${1:-}" = "--idle" ]; then MODE=idle; shift; fi
BASE=${1:-http://127.0.0.1:8888}
SECS=${2:-6}
THRESH=${CLOCK_MIN_MHZ:-1200}

SELF=$(hostname)
read -r -a WORKERS <<<"${WORKER_HOSTS:-}"
NODES=("$SELF" "${WORKERS[@]}")

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

sample_one() {  # host outfile
  local h="$1" out="$2"
  if [ "$h" = "$SELF" ]; then
    timeout "$((SECS + 2))" nvidia-smi --query-gpu=clocks.sm,utilization.gpu --format=csv,noheader -lms 250 >"$out" 2>/dev/null
  else
    ssh -o ConnectTimeout=6 -o BatchMode=yes "$h" \
      "timeout $((SECS + 2)) nvidia-smi --query-gpu=clocks.sm,utilization.gpu --format=csv,noheader -lms 250" >"$out" 2>/dev/null
  fi
}

load_pid=""
if [ "$MODE" = load ]; then
  python3 - "$BASE" <<'PY' >/dev/null 2>"$tmp/load.err" &
import json, sys, urllib.request
base = sys.argv[1].rstrip("/")
body = json.dumps({"text": "Write a detailed essay about distributed systems.",
                   "sampling_params": {"max_new_tokens": 400, "temperature": 0.0, "ignore_eos": True}}).encode()
req = urllib.request.Request(base + "/generate", data=body, headers={"Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=600).read()
except Exception as exc:  # noqa: BLE001
    print(f"[!] load request failed: {exc!r}", file=sys.stderr)
PY
  load_pid=$!
fi

echo "=== GPU 时钟体检 $(date '+%F %T')  模式=$MODE  时长=${SECS}s ==="
samp_pids=()
for i in "${!NODES[@]}"; do
  sample_one "${NODES[$i]}" "$tmp/n$i.txt" &
  samp_pids+=($!)
done
for p in "${samp_pids[@]}"; do wait "$p"; done
[ -n "$load_pid" ] && kill "$load_pid" 2>/dev/null

printf "%-24s %9s %9s %7s  %s\n" "node" "median" "max" "util" "verdict"
fail=0
for i in "${!NODES[@]}"; do
  f="$tmp/n$i.txt"
  if [ ! -s "$f" ]; then printf "%-24s %9s\n" "${NODES[$i]}" "NO DATA"; fail=1; continue; fi
  med=$(sed -E 's/ MHz, / /; s/ %//' "$f" | awk '{print $1+0}' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
  max=$(sed -E 's/ MHz, / /; s/ %//' "$f" | awk '{print $1+0}' | sort -n | tail -1)
  util=$(sed -E 's/ MHz, / /; s/ %//' "$f" | awk '{print $2+0}' | sort -n | tail -1)
  verdict="OK"
  if [ "${util:-0}" -ge 50 ] && [ "${med:-0}" -lt "$THRESH" ]; then verdict="X 疑似锁频"; fail=1; fi
  printf "%-24s %6s MHz %6s MHz %6s%%  %s\n" "${NODES[$i]}" "$med" "$max" "$util" "$verdict"
done

echo
if [ "$fail" = 0 ]; then
  echo "结论：三台时钟正常（阈值 ${THRESH} MHz）。"
else
  [ -s "$tmp/load.err" ] && { echo "负载请求："; cat "$tmp/load.err"; }
  echo "结论：有节点未升频。若该节点 -lgc 3003 也拉不起来 ⇒ 断电 30–60 s 复位（软重启未必够）。"
  echo "      复位后重跑本脚本；仍不恢复再查供电/散热/固件。"
  exit 1
fi
