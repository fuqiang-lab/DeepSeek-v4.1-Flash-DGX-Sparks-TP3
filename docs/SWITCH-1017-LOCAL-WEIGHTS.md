# 切换到 DeepSeek-V4.1-Flash-1017（三台全本地权重，无 NFS）

> 执行：2026-10-17 21:25 → 2026-10-18 02:10（北京）。节点 `fq-dgx-01/02/03`，
> 内核 `6.17.0-1031-nvidia`，驱动 `580.173.02`，TP=3 / EP=1 over RoCE。
> 本文只记录**这一轮实际做了什么、实测到什么**；部署基线仍见
> [`DEPLOY-RECORD-dsv41.md`](DEPLOY-RECORD-dsv41.md) 与 [`DEPLOY-GUIDE.md`](DEPLOY-GUIDE.md)。

## 0. 结论

- **1017 已上线**：三台各持一份本地权重（476 GiB）+ 各自本地 Engram 表，
  **运行期完全没有 NFS**（无 `dsv41-nfs` 容器、worker 无 nfs 挂载、无 `dsv41-weights` 卷）。
- 权重逐台独立校验：`sha256sum -c` **48/48 OK ×3 台**（对 ModelScope 官方清单）。
- Engram 6 个分片全部重建；**尺寸与旧版逐字节相同、内容哈希全部不同**（见 §2.2）。
- 质量门 **6/6**；RoCE 正常（`via NET/IB` 64 条、`ibv_reg_mr_iova2` 0 次）；
  两层 Engram 都有实际读取（`lookups=17344`）。
- 权重加载：worker 由 **445/413 s → 211/194 s（−53%）**；head 仍是长杆
  **634 s + drafter 155 s**（比 NFS 时代 659 s 基本不变 ⇒ **head 慢不是 NFS 造成的**）。
- 起服到 `health=200`：**1029 s**。

## 1. 为什么从 NFS 改成本地副本

旧架构是 head 单盘经 NFSv4 供三份（三 rank 合计从 head 单盘读约 298 GB / 659 s ≈ 450 MB/s），
瓶颈在 **head 的 NVMe**，不在网络。改成本地副本后：

| | NFS 模式 | 本地模式 |
|---|---|---|
| worker 权重来源 | head 单盘经 NFSv4 | 各机本地 NVMe |
| 单节点磁盘占用 | head 476 GiB，worker 0 | 每台 476 GiB |
| worker 加载耗时（实测） | 445.58 / 412.97 s | **211.06 / 193.60 s** |
| head 加载耗时 | 659.27 s | 633.74 s |
| 运行期 NFS 依赖 | 有 | 无 |

代价是容量：切换后 head 1.4 T 可用、node2 2.5 T、node3 964 G（node3 最紧，仍够）。

## 2. 两个会**静默**出错的陷阱（本轮都实测坐实）

### 2.1 NFS 导出会继续用旧目录（只在回 NFS 模式时相关）

`dsv41-nfs` 容器是直接 `-v "$MODEL_DIR:/export:ro"` 导出的，**不是**导出
`~/.cache/huggingface/export`。而 `start.sh`：

- `nfs_ensure_server()` 只要发现活容器就复用（`NFS_REUSE_EXPORT=1`）；
- `nfs_publish_model()` 在「导出目录已有 ≥48 个分片」时**直接 return**。

⇒ 只改 `MODEL_DIR` 然后 `share`：head 读新权重、worker 仍读旧权重，
`share`/`serve`/三层验证**全部显示成功**，没有一条报错。

本轮处置：切到本地位权模式，彻底绕开 NFS；同时 `docker rm -f dsv41-nfs`、
删掉 worker 的 `dsv41-weights` 卷。**若将来回 NFS 模式，换模型前必须先删 NFS 容器。**

### 2.2 `pack_engram.py` 的幂等判断只比尺寸

新旧 checkpoint 的 Engram 张量在 dtype / shape / data_offsets 上**完全相同**
（`weight [384006168,256] F8_E4M3`、`scale [384006168,8] F8_E8M0`，见 2026-10-18 的
shape 比对），因此 `pack` 的输出尺寸**必然相同**，而 `pack_engram.py:70` 的判据是

```python
if target.exists() and target.stat().st_size == expected:  # already complete
```

⇒ **不显式删旧分片，`pack` 会打印 already complete 并跳过，服务带着旧行表启动且不报错。**

本轮证据（重建前后）：

| 文件 | 尺寸 | 旧 SHA256 → 新 SHA256 |
|---|---|---|
| head `engram-l1-r0of3.bin` | 33,792,546,880 | `f6fb8f86…` → `6474bfc2…` |
| head `engram-l14-r0of3.bin` | 33,793,471,936 | `6490997a…` → `3c458d09…` |
| n2 `engram-l1-r1of3.bin` | 33,792,546,880 | `784ab905…` → `9e915143…` |
| n2 `engram-l14-r1of3.bin` | 33,793,472,200 | `3aa1da75…` → `8926bf1a…` |
| n3 `engram-l1-r2of3.bin` | 33,792,546,880 | `24572643…` → `25b90fa4…` |
| n3 `engram-l14-r2of3.bin` | 33,793,472,200 | `32dd215f…` → `19e611e2…` |

**尺寸全同、哈希全异** —— 尺寸类检查（包括 `pack` 自带的幂等判断）无法区分新旧行表。
`cmd_pack` 现在会在发现旧分片时打印警告。

## 3. 实现：`WEIGHT_MODE=local`

`.env` 新增三项（`MODEL_DIR` 改为新目录）：

```bash
MODEL_DIR=$HOME/models/DeepSeek-V4.1-Flash-1017
WEIGHT_MODE=local
WORKER_MODEL_DIR=$HOME/models/DeepSeek-V4.1-Flash-1017
WEIGHT_SYNC_JOBS=8
```

`start.sh` 的改动（`fleet/start.sh`，1036 行）：

| 位置 | 行为 |
|---|---|
| `cmd_sync`（新） | 把 checkpoint rsync 到每台 worker；`worker_has_local_model` 先比对 48 分片**字节总和**，一致就跳过 ⇒ 可反复执行 |
| `cmd_share` | `local` 模式下等价于 `cmd_sync`；`nfs` 模式保持原行为 |
| `cmd_pack` | worker 源改为 `-v $WORKER_MODEL_DIR:/models/DeepSeek-V4.1-Flash:ro`（NFS 模式仍用卷） |
| `cmd_serve` | worker 权重挂载同上；启动前检查本地 `config.json`；NFS 相关检查仅在 `nfs` 模式执行 |
| `cmd_doctor` / `cmd_status` | 按模式打印/检查对应路径 |

**容器内挂载点始终是 `/models/DeepSeek-V4.1-Flash`**，`DSV41_SOURCE` / `MODEL_PATH`
不变，所以引擎参数、adapter、`.env` 其余项一律不用动。

`svc.sh` 的 `do_share` 识别两种模式，并把超时从 600 s 放宽到 `SHARE_TIMEOUT`（默认 3600 s，
首次要传 476 GiB）。

## 4. 传输实测（RoCE 织网）

管理网是 WiFi（head `192.168.0.86`），批量传输必须走织网
（`10.100.180.x` / `10.100.178.x`，200 Gb/s，MTU 9000）。

| 方式 | 吞吐 |
|---|---|
| 单条 ssh 流 `chacha20-poly1305` | 64 MB/s |
| 单条 ssh 流 `aes256-gcm` | 93 MB/s |
| 4 条并行 `aes256-gcm` | 354 MB/s |
| **实际：每节点 6 流、两节点并行** | **≈270 MB/s/节点，合计 ≈540 MB/s** |

476 GiB/节点、两节点并行，**耗时 29.5 min**（00:53:47 → 01:23:14）。

## 5. 实际执行流水

| 时刻 | 动作 |
|---|---|
| 00:12 | 下载完成校验：48/48 OK（前一阶段） |
| 00:53–01:23 | `sync-1017.sh` 把 476 GiB 推到 node2/node3 |
| 01:23–01:29 | 两台 worker `LC_ALL=C sha256sum -c`：48/48 OK |
| 01:29 | `./svc.sh stop`，三台无引擎容器、GPU 计算进程 0 |
| 01:30 | 删三台旧 Engram（6 文件），确认清空 |
| 01:30:37–01:41:28 | `./start.sh pack`：head 2×128 s，worker 各约 2×128 s |
| 01:41–01:44 | 重建前后哈希比对（上表） |
| 01:44 | `./svc.sh start 1800` |
| 02:01:47 | `health=200`（1029 s） |

## 6. 验收结果

| 项 | 结果 |
|---|---|
| `/health` | 200 |
| `/v1/models` | `deepseek-v4.1-flash`，`max_model_len=262144` |
| 三台容器 | `dsv41-head` / `dsv41-worker` ×2 全 healthy |
| 传输 | `via NET/IB` 64 条；`ibv_reg_mr_iova2` 0 次 |
| Engram | `layer=1/14 lookups=17344 hit_rate=0.0% packed=True`（0% 是 `DSV41_CACHE_GIB=0` 的设计值） |
| accept len | 3.17（哨兵区间 2.5–3.05 附近，**未塌**） |
| 质量门 | **6/6**（arithmetic / arithmetic2 / json / counting / list / prose） |
| 权重挂载 | 三台各自 `→ /home/fuqiang/models/DeepSeek-V4.1-Flash-1017` |
| NFS 残留 | 0 个 nfs 容器 / 0 个 nfs 挂载 / 0 个 `dsv41-weights` 卷 |

## 7. 性能：怎么比才不会比错

单流（`/generate`，300 tok，greedy，`ignore_eos`），按 `meta_info.spec_verify_ct` 拆开看：

| prompt 类型 | accept | step | tok/s |
|---|---|---|---|
| 可预测散文（termites） | 3.41 | 113.7 ms | 29.99 |
| 代码（`def quicksort`） | 3.70 | 123.1 ms | 30.09 |
| 中文短文 | 2.13 | 100.5 ms | 21.16 |
| 技术解释（CAP） | 2.75 | 122.2 ms | 22.53 |

`bench_migration.py`（chat 口径，3 次中位数）：

| 项 | 1017 本轮 | 09-25 记录表 |
|---|---|---|
| C1 散文 sampled | **18.56** | 33.80 |
| C1 散文 greedy | **16.98** | 34.99 |
| C1 代码 greedy | **41.49** | 78.94 |
| C4 聚合 | **40.01** | 75.47 |

**不要直接拿这两列下"回退 2×"的结论**。逐项排查后，找到两个独立原因：

### 7.1 主因：head 的 GPU 掉进 507 MHz 锁死（硬件状态，非权重问题）

高频采样（200 ms）实测：

```
head   解码中 94% 利用率：15 个采样全是 507 MHz / 507 MHz（gr）
node3  同 workload          ：2405–2424 MHz（上限 3003）
```

- `-lgc 3003` 强制最高时钟 → head 仍 507；`-rgc` 复位 → 仍 507；无常驻节流标志
  （`sw_power_cap` / `hw_thermal_slowdown` 全 Not Active）、无 Xid、温度 60 ℃。
- 这正是 `PITFALLS.md` 第 28 行记录的模式（「GPU 降频锁死：`nvidia-smi` 看不出，
  必须拔电源 30–60 s」）；该条同时给出旁证「单流 0.9 s ↔ 18 s 抖动、只有参考值 70–75%」。
- 后果：TP=3 每步由最慢 rank 决定。head 只有 1/5 时钟 ⇒ 该 rank 的那 1/3 工作量慢 5×，
  合成步时 ≈ 2.3× —— 与实测的 ~2× 回退吻合。
- **待做**：head 断电 30–60 s（软重启可能清不掉）后重跑 bench，预期单流回到 35–40 tok/s。

#### 7.1.1 复现与判定（2026-10-18 07:50 复查）

5.5 小时后仍复现：head 在 95% 利用率下 **507 MHz / 507 MHz（gr）/ 9.2 W**，
node3 同 workload **2411 MHz / 12.9 W**。

判定依据，以及一条被撤回的论据：

| 观察 | 含义 |
|---|---|
| 负载下 head 507 MHz，worker 2411 MHz | 同一 workload、同一驱动/内核，**只有 head** 不升频 |
| 功率随频率变化（head 9.5 W vs worker 12–31 W） | **不是 NVML 读数冻结**，是真停在低 P-state |
| 空闲 52 ℃、无 `sw_power_cap` / thermal 标志 / Xid | 排除温度与显式节流 |
| `-lgc 3003` 后 node3 也只有 2411 | ⚠️ 该平台上 `-lgc` 未必是"强制锁频"，所以**"lgc 无效"不能当证据**；真正的判据是"负载下 head vs worker 的频率差" |

**最可能的触发**（按可能性；需在重启后用上一次启动的日志确认）：

1. **停机窗口内自动挂起/恢复**：本轮 `stop`（01:29）到 `serve`（01:44）之间机器空闲 15 分钟，
   head 又是带图形会话的机器。GB10 上挂起/恢复后 DVFS 状态丢失、停在最低 P-state 是已知模式。
   查：`journalctl -b -1 | grep -iE "suspend|PM: suspend|resume"`。
2. **驱动热重载**（更新/ unattended-upgrade / dkms 重建后未做 GPU 复位）：
   查：`journalctl -b -1 | grep -iE "NVRM|nvidia"`。
3. **供电协商降档**（适配器/PD 协商到低预算，固件把时钟夹在最低档）。

**预防**：head 作为常驻服务机不应自动挂起 ——
`sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target`。

**体检脚本**：`scripts/check-gpu-clocks.sh`（在 head 上跑，发 400-token 负载并按节点采样，
util ≥ 50% 且中位时钟 < 1200 MHz 判为锁频）。重启后先跑它，再跑 bench。

#### 7.1.2 2026-10-18 重启后复查：确认是真实算力损失，且早于本次切换

系统更新并重启三台后（07:56），head 仍然 507 MHz。三条独立证据：

1. **纯计算微基准（1024³ bf16，3000 次，三台同容器同代码）**

   | 节点 | 耗时 | 算力 |
   |---|---|---|
   | head | 0.4500 s | **14.3 TFLOPS** |
   | node2 | 0.0992 s | 65.0 TFLOPS |
   | node3 | 0.1005 s | 64.1 TFLOPS |

   head 慢 **4.54×**，与 507/2400 ≈ 0.21 完全吻合 ⇒ **不是读数问题，是真实降频**。
2. **功耗同步**：负载下 head 9.5 W vs node2/3 27–30 W（P0，节流标志全 0）。
3. **dgx-monitor 历史**（`metrics.db`，`gpu_sm_clock_pct`）：
   head 自 **2026-10-17 10:05 起每个非伪值样本都是 16.9%**（507/3003），
   node2/3 全程 80–85%。⇒ **该状态早于 1017 切换（10-17 21:25 开始）**，
   也早于本地位权改造；10-17 记录的 41.33 tok/s 基线就是在这个状态下测的。

已排除：温度（52–60 ℃）、`sw_power_cap`/thermal 节流标志、Xid/NVRM 报错、
挂起恢复（上一次启动 10-12→10-18 无 suspend 记录）、驱动热重载、图形会话（gdm/X 均 inactive）、
软件时钟锁（`-lgc`/`-rgc` 无效）、VBIOS/GSP/驱动/内核差异（与 node2/3 完全一致）。
**软重启不清除**。

结论：这是 head 板级的低时钟/供电限制（或卡死的固件电源状态），软件侧无解。
下一步：**断电 30–60 s**（软重启不够）；仍不复位则按硬件故障报 NVIDIA DGX Spark 支持，
证据即上表（P0、无节流原因、507/3003、14.3 vs 65 TFLOPS、9.5 W vs 27 W）。

**若需立刻恢复性能**：本地位权模式下三台权重/Engram 全在本地，理论上可把 head 角色
迁到 node2（改 `HEAD_IP` / `WORKER_IPS` / `WORKER_HOSTS` 即可），但这会改变 API 入口，
需单独验证，暂不执行。

### 7.2 次因：k=5 vs k=3 的口径不可比

- 09-25 那张表是 **k=3 时代**（`DSPARK_BLOCK_SIZE=3`，4-token 验证窗）；
  现役 `.env` 是 **k=5**（6-token 验证窗），步时约 1.5×，正对应 Engram 查找量
  （查找数 ∝ 每步验证的 token 数）。
- 10-12 的旧日志在 accept=5.05 时 `gen throughput=40.19` ⇒ step=125.6 ms，
  与当前 100–123 ms 同量级 —— **本地位权切换本身没有引入 compute 回退**。
- 差异的剩余部分来自 **accept（内容决定）**：同一硬件单流 15→51 tok/s 都出现过
  （`K3-VS-K5-AB-PLAN.md:85`）。

⇒ 顺序：先解决 7.1（断电），再决定是否做 `docs/K3-VS-K5-AB-PLAN.md` 的 k=3 A/B。
**在 507 MHz 锁死未解除前做任何 k 值 A/B 都是浪费。**

## 8. 回滚

旧权重仍在：head `~/NewModels/DeepSeek-V4.1-Flash`（476 G）、
node2 `~/NewModels/DeepSeek-V4.1-Flash`（244 G）、node3（233 G）——
**worker 两份是旧的、不完整**，不能直接在本地位权模式下起服务。

回滚步骤（≈40 min）：

```bash
cd ~/dsv41-3xspark
cp -a state/env.before-1017-1018-0055 .env     # MODEL_DIR 回旧路径
# 二选一：WEIGHT_MODE=nfs（并 docker rm -f dsv41-nfs 后再 share），或把旧权重补全到 worker
rm -f ~/dsv41-engram/engram-l*-r0of3.bin       # 旧行表已删，必须重打包
ssh fq-dgx-02.local 'rm -f ~/dsv41-3xspark/engram/engram-l*-r1of3.bin'
ssh fq-dgx-03.local 'rm -f ~/dsv41-3xspark/engram/engram-l*-r2of3.bin'
./start.sh share && ./start.sh pack && ./svc.sh start 1800
```

## 9. 遗留

- **head 断电 30–60 s 清时钟锁**（§7.1，最高优先；当前 head 恒 507 MHz）。
- **k=3 vs k=5 A/B**（等 §7.1 之后再做）。
- **长上下文未重测**：`CHUNKED_PREFILL_SIZE=1024` 的保护上界是针对旧权重的；
  上游「~200k prompt 打爆 Spark 主机」的失败模式仍未在 1017 上验证。
- **工具调用未在 1017 上验证**（`tool_call_parser=deepseekv41`）。
- **清理未做**：旧权重 476+244+233 G、`~/.cache/huggingface/export` 硬链接（第三份 inode）、
  ModelScope 缓存里的 Qwen3.8-Flash-Next 336 G + GLM-5.3-Flash 306 G。
