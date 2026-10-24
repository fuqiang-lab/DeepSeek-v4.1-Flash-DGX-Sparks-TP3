#!/usr/bin/env bash
# =============================================================================
# dsv41-watchdog.sh — 健康守护：head 的 /health 连续失败则整集群 stop+start
#   位置：head 的 ~/dsv41-3xspark/watchdog.sh（与 svc.sh 同目录，依赖其 .env）
#   由 dsv41-watchdog.timer 每 WATCH_INTERVAL 秒拉起一次（默认 120s）
#
# 为什么不是 docker --restart=unless-stopped：
#   TP=3 是锁步组。head 单容器被 docker 拉起后，会用 dist_init_addr=head:20000 等
#   另外两个 rank；而 worker 那边还挂在旧的 NCCL 状态上，等 1800s watchdog 兜底。
#   结果是"起来了一个半残集群"，比不起来更难查。所以守护必须整集群重启。
#
# 行为：
#   /health 200                       → 计数归零，退出
#   起服窗口内（serve-*.log 年轻）      → 不插手，退出
#   连续 FAIL_THRESHOLD 次失败          → 归档三台 docker logs → ./svc.sh restart
#   6 小时内已尝试 MAX_ATTEMPTS 次      → 写 GIVE_UP 标记并放弃（要人来看）
#   任何时刻只允许一个实例（flock）
#
# 退出码（配合 systemd：只有真正需要人来处理时才非零，否则 status 会一片红）：
#   0 = 健康 / 已跳过（起服中、已有实例）/ 已重启
#   1 = 放弃自动恢复，或重启流程失败（需要人工介入）
# =============================================================================
set -u
cd "$(dirname "$0")" || exit 1
[ -f .env ] || { echo "找不到 .env（必须在 svc.sh 同目录执行）" >&2; exit 1; }
set -a; . ./.env; set +a

PORT=${PORT:-8888}
HEALTH_URL="http://127.0.0.1:${PORT}/health"
WATCH_INTERVAL=${WATCH_INTERVAL:-120}     # 与 timer 周期保持一致（仅用于日志）
START_GRACE=${START_GRACE:-2400}          # serve-*.log 比这年轻就认为还在起服/刚起服
FAIL_THRESHOLD=${FAIL_THRESHOLD:-3}       # 连续失败次数（3 × 120s ≈ 6 分钟）
MAX_ATTEMPTS=${MAX_ATTEMPTS:-3}           # 窗口内最多重启次数
ATTEMPT_WINDOW=${ATTEMPT_WINDOW:-21600}   # 6 小时
RESTART_WAIT=${RESTART_WAIT:-1800}

STATE_DIR=./state/watchdog
LOGDIR=./logs
mkdir -p "$STATE_DIR" "$LOGDIR"
FAIL_FILE=$STATE_DIR/consecutive_failures
ATTEMPT_FILE=$STATE_DIR/attempts.log
GIVEUP_FILE=$STATE_DIR/GIVE_UP
LOCK_FILE=$STATE_DIR/lock
HEALTHY_MARK=$STATE_DIR/healthy_mark      # 记录"最近一次健康时的 serve 日志名"
touch "$FAIL_FILE" "$ATTEMPT_FILE" 2>/dev/null || true

ts()  { date '+%F %T'; }
log() { echo "[$(ts)] $*"; }

exec 9>"$LOCK_FILE"
flock -n 9 || { log "已有实例在跑，跳过"; exit 0; }

# --- 0) 放弃标记 ------------------------------------------------------------
if [ -f "$GIVEUP_FILE" ]; then
  log "GIVE_UP 标记存在（$(cat "$GIVEUP_FILE")）——不再自动重启，需人工处理后删除该文件"
  exit 1
fi

# --- 1) 健康优先：服务活着就归零退出（宽限只保护"还没起来"，不保护"已经起来又崩了"）
if curl -fsS -m 10 "$HEALTH_URL" >/dev/null 2>&1; then
  [ -s "$FAIL_FILE" ] && [ "$(cat "$FAIL_FILE")" != "0" ] && log "health 恢复 200，计数归零"
  echo 0 >"$FAIL_FILE"
  ls -t serve-*.log 2>/dev/null | head -1 >"$HEALTHY_MARK"   # 记录"这一轮已经健康过"
  exit 0
fi

# --- 1b) 起服窗口内不插手 ---------------------------------------------------
if pgrep -f 'start\.sh serve' >/dev/null 2>&1; then
  log "检测到 start.sh serve 正在运行，跳过"; echo 0 >"$FAIL_FILE"; exit 0
fi
newest=$(ls -t serve-*.log 2>/dev/null | head -1)
seen=$(cat "$HEALTHY_MARK" 2>/dev/null || true)
if [ -n "$newest" ] && [ "$newest" != "$seen" ]; then
  # 这一轮还没健康过（含首次起服 / 起服中 / 起服失败）→ 按年龄给宽限
  age=$(( $(date +%s) - $(stat -c %Y "$newest") ))
  if [ "$age" -lt "$START_GRACE" ]; then
    log "serve 日志 $newest 仅 ${age}s 前且本轮未健康过，处于起服窗口(<${START_GRACE}s)，跳过"
    echo 0 >"$FAIL_FILE"; exit 0
  fi
  log "serve 日志 $newest 已 ${age}s 仍未健康过（起服卡死？）→ 进入失败计数"
else
  log "本轮已健康过（$seen）后失败 → 直接进入失败计数，不享受宽限"
fi

# --- 3) 连续失败计数 --------------------------------------------------------
n=$(( $(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FAIL_FILE"
log "health 失败 ${n}/${FAIL_THRESHOLD}（$HEALTH_URL）"
[ "$n" -lt "$FAIL_THRESHOLD" ] && exit 0

# --- 4) 防抖：窗口内尝试次数 ------------------------------------------------
now=$(date +%s)
: >"$ATTEMPT_FILE.new"
while read -r t; do [ -n "$t" ] && [ $(( now - t )) -lt "$ATTEMPT_WINDOW" ] && echo "$t" >>"$ATTEMPT_FILE.new"; done <"$ATTEMPT_FILE" 2>/dev/null
mv -f "$ATTEMPT_FILE.new" "$ATTEMPT_FILE"
tries=$(wc -l <"$ATTEMPT_FILE")
if [ "$tries" -ge "$MAX_ATTEMPTS" ]; then
  echo "$(ts) 已达 $MAX_ATTEMPTS 次上限" >"$GIVEUP_FILE"
  log "!! ${ATTEMPT_WINDOW}s 内已重启 ${tries} 次仍不健康 → 放弃自动恢复（人工介入后删 $GIVEUP_FILE）"
  exit 1
fi

# --- 5) 抢救现场：三台 docker logs + 内核日志 -------------------------------
INC=logs/incident-$(date +%Y%m%d-%H%M%S)
mkdir -p "$INC"
SSH="ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"
SELF=$(hostname)
WORKERS=(); read -r -a WORKERS <<<"${WORKER_HOSTS:-}"
node_do() { local h=$1; shift
  if [ "$h" = "localhost" ] || [ "$h" = "$SELF" ]; then bash -c "$*"; else $SSH "$h" "$*"; fi; }

log "归档现场 → $INC"
for h in localhost "${WORKERS[@]:-}"; do
  [ -z "${h:-}" ] && continue
  node_do "$h" "docker logs --tail 5000 dsv41-head   > /tmp/wd-\$(hostname)-head.log   2>&1 || true"
  node_do "$h" "docker logs --tail 5000 dsv41-worker > /tmp/wd-\$(hostname)-worker.log 2>&1 || true"
  node_do "$h" "docker ps -a --format '{{.Names}}|{{.Status}}' | sed 's/^/[ps] /' > /tmp/wd-\$(hostname)-ps.txt 2>&1 || true"
  tag=$(node_do "$h" 'hostname' 2>/dev/null | tr -d '\r')
  for f in head worker; do
    node_do "$h" "cat /tmp/wd-${tag}-${f}.log 2>/dev/null" | sed 's/\r$//' > "$INC/${tag}-${f}.log" 2>/dev/null || true
  done
  node_do "$h" "cat /tmp/wd-${tag}-ps.txt 2>/dev/null" | sed 's/\r$//' > "$INC/${tag}-ps.txt" 2>/dev/null || true
done
journalctl -k --since '-15 min' > "$INC/kernel-head.log" 2>&1 || true
sar -r > "$INC/sar-head.log" 2>&1 || true
rm -f /tmp/wd-*.log /tmp/wd-*.txt 2>/dev/null || true

# --- 6) 整集群重启（复用 svc.sh，不重复实现） -------------------------------
echo "$now" >>"$ATTEMPT_FILE"
echo 0 >"$FAIL_FILE"
log "执行整集群重启：./svc.sh restart $RESTART_WAIT（日志 $INC/restart.log）"
if ./svc.sh restart "$RESTART_WAIT" >>"$INC/restart.log" 2>&1; then
  log "重启流程返回成功；最终健康以 /health 为准"
else
  log "!! 重启流程返回失败，详见 $INC/restart.log"; RC=1
fi
tail -5 "$INC/restart.log" 2>/dev/null | sed 's/^/    | /'
exit "${RC:-0}"
