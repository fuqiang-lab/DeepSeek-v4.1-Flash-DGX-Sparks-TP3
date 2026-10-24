# 事件：2026-10-25 head 整机 OOM（内核 OOM killer 杀引擎，三节点服务全宕 6 小时）

> 发生：2026-10-25 00:58:27–00:59:14 CST（本轮运行 15 h 31 min 后）。
> 节点 `fq-dgx-01/02/03`，引擎 `dsv41-3xspark:local`（SGLang dev-dsv41 + DeepSeek-V4.1-Flash-1017，TP=3 / nnodes=3，DSPARK MTP）。
> 恢复：2026-10-25 07:16 `svc.sh start 1800`，481 s 后 `health=200`，三层验证通过（RoCE 64 条 via NET/IB，`ibv_reg_mr` 0 次）。
> 关联：[`INCIDENT-2026-10-23-ALLREDUCE-STALL.md`](INCIDENT-2026-10-23-ALLREDUCE-STALL.md)（**不同签名，勿合并**）、
> [`PITFALLS.md`](PITFALLS.md) §4.6（长 prefill 内存墙）、[`BATCH-MIGRATION-2026-09-25.md`](BATCH-MIGRATION-2026-09-25.md) §5（chunk 1024 vs 768）。

## 0. 结论

- **定性（确定）**：head 发生**整机级（global）内核 OOM**。`00:58:27`–`00:59:03` 共 **10 次**
  `invoked oom-killer`，最后一次杀掉 pid 3171098 `sglang::schedul`
  （`total-vm:420328836kB, anon-rss:5086796kB`），容器 `OOMKilled=true`，`00:59:14` exit **247**。
  被杀名单里同时有 pipewire / dbus-daemon / snap / systemd(user) / sshd —— 说明是**整机内存耗尽**，
  不是容器 cgroup 超限（容器 `HostConfig.Memory=0`，无限制）。
- **直接后果**：head 的 TCPStore 消失 → 两台 worker `00:59:03` 报
  `recvValue failed ... Did the remote server shutdown or crash?` → TP 组 ALLREDUCE
  `01:07:04` 报 600 s 超时（`last started work: -1`）→ `01:21:26` watchdog 自身卡 480 s →
  `01:30:05/08` SIGABRT，**exit 3**。worker 是"收尸"，不是原因。
- **放大器（确定）**：容器 `--restart=no`（`fleet/start.sh:813`）+ `dsv41.service` 是
  `Type=oneshot, RemainAfterExit=yes`（`scripts/dsv41.service:9-10`），10-24 那次恢复还是手工
  `./svc.sh start`，**当前运行根本没有守护** ⇒ 崩了就是永久宕机，直到人发现（本次 6 小时）。
- **触发（高度可疑，未定案）**：崩溃时段是全天负载最重 + 上下文最长的一段——
  首次出现 **>200k** 上下文（`#cached-token: 243968` / **246784**，当日其它时段最大仅 196352），
  且崩溃前 **83 s** 出现本轮唯一一次非启动期的驱动级分配失败
  `NVRM: ... Out of memory [NV_ERR_NO_MEMORY] ... _memdescAllocInternal`。这与
  [`BATCH-MIGRATION-2026-09-25.md`](BATCH-MIGRATION-2026-09-25.md):211-220 记录的上游失败模式同型。
- **未定案（诚实边界）**：无法指认"到底哪个分配越线"——GB10 上
  `nvidia-smi --query-gpu=memory.*` 恒为 `[N/A]`，没有 GPU 内存遥测，也没有 per-PID 采样，
  `sar` 只有 10 min 粒度。**能确定的只有"内存余量结构性偏小 + 长上下文瞬时峰值"这个组合。**

## 1. 时间线（CST；容器日志本身是 UTC，已 +8 对齐到 sar/journal 的本地时间）

| 时间 | 节点 | 事件 |
|---|---|---|
| 10-24 09:28 | head | 容器启动（`StartedAt=2026-10-24T01:28:33Z`），本轮 uptime 15 h 31 min |
| 10-24 全天 | head | `sar` 内存占用 **94.06–97.06%**，余量仅 1.0–4.3 GB（该机常态） |
| 00:43 / 00:49 | head | 大 prompt 进入：`#pending-token: 59606` / `64811` |
| **00:51:46** | head | detokenizer 心跳停更，此后**再未恢复** |
| 00:52:06 | head | 起 `Health check failed: couldn't get a response from detokenizer`，连续到崩溃（当天累计 506 次；按 UTC 分时统计，UTC 04–11（CST 12:00–19:59）与 UTC 15–16（CST 23:00–00:59）两段较密，其中末段是**连续且不恢复**的） |
| **00:52:31 / 00:55:14** | head | **`#cached-token: 243968` / `246784`** —— 全天首次突破 200k |
| 00:56:19 | head | 最后一条 `Decode batch`（此后无前向；同期 decode 吞吐曾掉到 5.2–5.7 tok/s） |
| **00:57:04** | head | 内核 `NVRM: Out of memory [NV_ERR_NO_MEMORY]`（非启动期唯一一次） |
| 00:57:04 | dgx-02 | rank1 最后一次成功 collective（600 s 后即 01:07:04 的超时点） |
| **00:58:27–00:59:03** | head | 内核 **10 次** oom-killer；`Mem-Info` 显示 `Node 0 Normal free:240720kB`、`active_file:376kB`（page cache 被榨干），最终杀 `sglang::schedul` |
| 00:59:14 | head | 容器 exit **247**，`oom=true` |
| 00:59:03 | dgx-02/03 | TCPStore `recvValue failed ... remote server shutdown or crash?` |
| 01:07:04 | dgx-02 | `Watchdog caught collective operation timeout: ALLREDUCE ... ran for 600037 ms`，`last started work: -1` |
| 01:21:26 | dgx-02 | `ProcessGroupNCCL's watchdog got stuck for 480 seconds` |
| 01:30:05 / 01:30:08 | dgx-03 / dgx-02 | `Scheduler or DataParallelController terminated with -6` → exit **3**（watchdog_timeout=1800 s 兜底） |
| **07:16–07:24** | head | 恢复（见 §5）；服务已停 **6 小时 15 分** |

## 2. 证据与获取方式（全部可复现，均为只读命令）

```bash
docker ps -a --format '{{.Names}}|{{.Status}}'          # head: Exited (247)；worker ×2: Exited (3)
docker inspect --format '{{.State.ExitCode}} {{.State.OOMKilled}} {{.State.FinishedAt}}' dsv41-head
journalctl -k --since "2026-10-25 00:55" --until "2026-10-25 01:02" | grep -E 'invoked oom-killer|Out of memory|Mem-Info|Tasks state'
sar -r -f /var/log/sysstat/sa24                          # 10-24 全天水位
sar -r -f /var/log/sysstat/sa25 -s 00:30:00 -e 01:10:00   # 崩溃前后
docker logs dsv41-head | grep -E 'Health check|scheduler_0|crashed with exit code'
```

**归档（本次现场已抢救，含 sha256；容器已被 `start.sh serve` 的 `docker rm -f` 删除）**：

| 节点 | 路径 | 大小 | 内容 |
|---|---|---|---|
| fq-dgx-01 | `~/incident-20261025-0059/` | 14 MB | head 容器日志 98k 行、inspect、内核 OOM 全量 dump、journal、sar 3 份、`sa24`/`sa25` 原始文件、快照 |
| fq-dgx-02 | `~/incident-20261025-0059/` | 4.4 MB | worker 日志、inspect、内核日志、快照 |
| fq-dgx-03 | `~/incident-20261025-0059/` | 3.7 MB | 同上（其内核窗口为空 = 该机无 OOM） |

## 3. 根因分层：内存余量从哪来、到哪去

**池的总量**：`Reported total GPU memory per device (MiB): [124610]` = 121.7 GiB，
GB10 上 GPU 与 OS **同一个池**（`free` 看到的是同一份）。

**起服即占满**（head 日志）：

```
Load weight end  ... mem usage=99.12 GB   → avail mem=12.01 GB
Load weight end  ... mem usage=2.20 GB    → avail mem=9.55 GB   (drafter)
Memory pool end. avail mem=7.23 GB
max_total_num_tokens=749824 ... available_gpu_mem=5.18 GB
```

**起服后实测（2026-10-25 07:26）**：

| 项 | 值 |
|---|---|
| `MemAvailable` | **3.48–3.99 GB**（崩溃时 `sar` 记录 **0.995 GB**） |
| 引擎容器 cgroup `anon` / `file` / `shmem` / `slab` | 7359 MB / 1832 MB / 489 MB / 223 MB |
| 内核 `Slab`（含 `SUnreclaim`） | 1414 MB（1117 MB） |

⇒ 干净启动也只有 3.5–4 GB 余量，长跑后掉到 1 GB 左右；**任何 ≤2 GiB 的长上下文瞬时缓冲
（`DSV41_INDEXER_CHUNKED=1` 封顶在 2048 MiB fp32 logits，见 head 日志第 25051 行）都能把它顶穿。**

**非必需进程审计（结论：清不掉这个窟窿）**：常驻的非系统必需进程合计只有 **~50–60 MB**
（dgx-dashboard-admin anon 4.1 MB、pipewire 栈 ~18 MB、snap/fwupd ~15 MB、系统基础服务 ~20 MB）。
注意 `systemctl show -p MemoryCurrent dgx-dashboard-admin` 会显示 386 MB，但其中
anon 仅 4 MB、slab 46 MB，其余是可回收 cache —— **别被这个数字骗**。

## 4. 与 2026-10-23 事件的区别（重要：不是同一类故障）

| | 10-23 ALLREDUCE 停滞 | **10-25 本事件** |
|---|---|---|
| 内核 OOM | **无**（journal 自 10-18 08:36 持久化；10-24 01:00–02:00 CST 内 0 次，正是 10-23 17:17–17:34 UTC 的崩溃窗口） | **10 次**，杀到调度器 |
| NVRM 报错 | 无 | `NV_ERR_NO_MEMORY`（崩溃前 83 s） |
| 三机是否同时沉默 | 是（Engram 统计三台齐停） | 否（head 独死，worker 活了 31 min 等人） |
| 谁先死 | 同时 | head 先死，worker 是收尸 |
| 根因状态 | 未定案（现场丢失） | 机理确定（整机 OOM）；触发未定案 |

**对 10-23 复盘的一条更正**：该文 §4 把"内核 journal 读不到"列为观测缺口，实际情况是
`fuqiang` 属 `adm` 组，**`journalctl -k` 不需要 sudo 就能读**（只有 `dmesg` 被
`kernel.dmesg_restrict` 挡住）。本次正是靠这条通路拿到全部 OOM 现场；那篇文档的该条结论应作废。

## 5. 恢复记录（2026-10-25）

```bash
cd ~/dsv41-3xspark && ./svc.sh start 1800
```

- 预检 8/8 ✓（内核 `6.17.0-1031-nvidia`、`CmaTotal=131072 kB`、驱动 `580.173.02`、
  镜像 `dsv41-3xspark:local`、三台无 GPU 计算进程、12 个 IB 口全 ACTIVE）；
- share 本地权重 2/2 ✓；`serve-1025-0718.log`；**health=200 @ 481 s**；
- 三层验证：`/health` 200 · `deepseek-v4.1-flash` 262144 · 三台 `(healthy)` ·
  `via NET/IB` 64 条 · `reg_mr` 失败 0 · nonce 正确；
- 端到端冒烟：`POST /v1/chat/completions` → 正常返回，`usage` 10/13/23 tokens。
- **配置未做任何修改**（`.env` 一行未动）。

## 6. 新增：整集群重启守护（本次唯一的行为变更）

**为什么不用 `docker --restart=unless-stopped`**：TP=3 是锁步组。dockerd 单独拉起 head 后，
它用 `dist_init_addr=head:20000` 等另外两个 rank，而 worker 仍挂在旧 NCCL 状态上，
等 1800 s watchdog 兜底 ⇒ 得到"半残集群"，比不起来更难查。**守护必须整集群重启。**

| 文件 | 作用 |
|---|---|
| [`scripts/dsv41-watchdog.sh`](../scripts/dsv41-watchdog.sh) | 健康判断 / 连续失败计数 / 防抖 / 现场归档 / 调 `svc.sh restart` |
| [`scripts/dsv41-watchdog.service`](../scripts/dsv41-watchdog.service) | `Type=oneshot`、`User=fuqiang`、`TimeoutStartSec=3600`、`KillMode=process` |
| [`scripts/dsv41-watchdog.timer`](../scripts/dsv41-watchdog.timer) | `OnBootSec=10min` + `OnUnitActiveSec=2min` |

参数：连续 **3 次**（≈6 min）`/health` 失败才动手 → 先把三台 `docker logs` 归档到
`logs/incident-<ts>/` → `./svc.sh restart 1800`；**6 h 内最多 3 次**，超限写
`state/watchdog/GIVE_UP` 并 exit 1（systemd 显红等人处理）；`flock` 单实例。
"健康过一次"后不再享受 2400 s 起服宽限（否则"刚起来又崩"会被宽限吃掉）。

验证矩阵：起服中跳过 / 健康 / 健康后失败立即计数 / 达阈值→归档+restart / 6h 超限→GIVE_UP /
GIVE_UP 存在→exit 1，六条分支均已实测（前两条真机，其余在 `/tmp` 隔离环境用假 `svc.sh`）。
**未验证**：真实 `svc.sh restart` 的端到端（要再停一次服务），留待首次真实故障。

回滚：`sudo systemctl disable --now dsv41-watchdog.timer` + 删 `/etc/systemd/system/dsv41-watchdog.*`
与 `~/dsv41-3xspark/watchdog.sh`。

## 7. 防误判清单

- **不要**看到 worker 的 `ALLREDUCE timeout` 就去查 fabric —— 本事件里它是 head 死亡后的
  31 分钟回声，`last started work: -1` 的含义是"这条 collective 从未开始"。
- **不要**用降低 `MEM_FRACTION_STATIC` 来"腾内存"：`README.md:262` 记录低于 0.944 会直接
  报 `weights leave no GPU memory for the KV cache`。
- **不要**用 `systemctl show -p MemoryCurrent` 判断某个服务"吃了 386 MB"（含可回收 cache）。
- **不要**用 GPU 空闲时的 `clocks.sm` 判降频：本 fleet 实测该查询会返回 0 / 858 / 25850 MHz
  （`clocks.max.sm=3003`），是读取噪声。判 507 MHz 那类事故必须**带负载**测。
- 空闲时 `nvidia-smi --query-gpu=memory.*` 恒 `[N/A]`，别以为采集脚本写错了。

## 8. 遗留与下一步（未执行，待决策）

1. **长上下文闸门（最高优先）**：`CHUNKED_PREFILL_SIZE` 1024 → 768（`~/dsv41-3xspark/.env:124`，
   代价预填 ≈−11~15%，见 [`INDEXER-CHUNKED-TP3-RESULTS.md`](INDEXER-CHUNKED-TP3-RESULTS.md):148），
   或把 `CONTEXT_LENGTH` 262144 → 200704（`.env:112`）/ 网关侧拒 >200k。崩溃前那个
   244k 上下文的请求来自客户端 `192.168.0.77`。
2. **内存遥测**：加 1 min 粒度的 `MemAvailable` + 采样落盘，并设阈值告警（崩溃时可用余量
   1.0 GB，若能提前 10 min 报警就完全不必宕 6 小时）。
3. **观测开关**：`NCCL_DEBUG=INFO` + `NCCL_DEBUG_FILE`、SGLang `crash-dump-folder`
   （10-23 复盘 §6 已建议，仍未落地）。
4. **顺带发现（未修）**：`nv-cpu-governor.service` 自 10-18 开机即 failed（缺
   `linux-tools-nvidia`，`cpupower` 退出 2）；`dspark-vllm.service` 仍是 failed 遗留；
   journal 占 2.7 GB 磁盘。
