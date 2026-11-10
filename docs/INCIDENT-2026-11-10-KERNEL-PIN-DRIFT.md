# 事件：2026-11-10 `dsv41.service` 启动失败（DGX OTA 把 GRUB 位置参数顶偏，起进无驱动内核）

> 发生：2026-11-10 01:29 OTA 安装；01:38 重启后 head / worker-02 起进 `7.0.0-1019-nvidia`；
> 08:06 手动 `systemctl start dsv41.service` 报 `control process exited with error code`（rc=1，507 ms 即退出）。
> 节点 `fq-dgx-01/02/03`，引擎 `dsv41-3xspark:local`（TP=3 / nnodes=3，`WEIGHT_MODE=local`）。
> 恢复：2026-11-10 08:48 改 GRUB 默认项 → 重启 01/02 → 自动起服；**467 s 见 `health=200`**，三层验证通过。
> 关联：[`INCIDENT-2026-10-25-HOST-OOM.md`](INCIDENT-2026-10-25-HOST-OOM.md)（恢复段格式沿用）、
> [`DEPLOY-GUIDE.md`](DEPLOY-GUIDE.md):237（`grub-reboot` 位置参数说明，**本事件正是它的长期隐患**）、
> [`../README.md`](../README.md):183（CMA 回归一行表）。

## 0. 结论

- **定性（确定）**：`dsv41.service` 是 `Type=oneshot` → `svc-boot.sh` → `svc.sh start`。它**只跑了 507 ms**
  就 `status=1/FAILURE`，即死在 `svc.sh` 的 `[1/5] 环境预检`（`svc.sh` 中 `preflight` 末尾的 `die`），
  根本没走到 share/serve。预检日志（`~/dsv41-3xspark/systemd-dsv41.log`）三项全红：
  内核 ≠ `6.17.0-1031-nvidia`、`CmaTotal=0 kB`、`nvidia-smi` 报 "couldn't communicate with the NVIDIA driver"。
- **根因（确定）**：`/etc/default/grub` 里是 **9 月写下的位置下标** `GRUB_DEFAULT="1>2"`。
  01:29 的 DGX OTA（`aptdaemon role='role-upgrade-system'`，装 `linux-image-7.0.0-1025-nvidia` 全套 +
  `dgx-spark-ota-update-meta 26.09.2→26.09.3` + `nvidia-spark-mlnx-firmware-manager 6.0.1`）重新生成
  grub.cfg，**新内核插到子菜单最前**：`1>2` 的含义从"6.17.0-1031"变成了"7.0.0-1019"。
- **为什么 1019 起不来**：`7.0.0-1019` 自 **2026-09-19 00:27** 换内核时就被移除了
  `linux-modules-nvidia-580-open-7.0.0-1019-nvidia`（`/var/log/dpkg.log.2.gz` 有记录，现为 `rc` 状态），
  `/lib/modules/7.0.0-1019-nvidia/` 下**没有任何 `nvidia.ko`**；三台里只有 `6.17.0-1031` 有
  `nvidia-580-open/nvidia.ko`（580.173.02）。叠加 1019 的 `CmaTotal=0`（CMA 回归），即便补上驱动 RoCE 也起不来。
- **为什么 worker-03 没事**：它 01:32 那次 apt 只装了 1025 的 headers/tools，**没装 `linux-image-7.0.0-1025`**
  （`/boot` 无 `vmlinuz-7.0.0-1025`），菜单顺序未变，`1>2` 仍指向 6.17.0-1031。
  **但下次它装到 1025 内核，同样会在重启时踩同一个坑** —— 说明根因是"位置参数 + OTA"，不是单机问题。
- **放大器（人为）**：watchdog 于 01:58 已因 6 h 内 3 次自愈上限写下 `state/watchdog/GIVE_UP`，
  之后每 2 分钟只打一行日志退出。所以从 01:58 到人工介入，**集群处于"既没服务、也没守护"的状态**（约 6 小时）。

## 1. 时间线（CST）

| 时间 | 节点 | 事件 |
|---|---|---|
| 11-04 13:01 | 三台 | 上一轮正常运行起点（6.17.0-1031，服务健康 5 天 +） |
| 11-10 **00:17 / 01:03** | head | 两次起服失败：`could not push dspark_sps.json to 192.168.0.102: No route to host`（worker-03 管理面 WiFi 不通，**与本次内核问题无关**） |
| 01:29:09 | head/02 | OTA 升级开始：装 `linux-image-7.0.0-1025-nvidia`、`linux-modules-7.0.0-1025-nvidia`、`linux-modules-nvidia-fs-7.0.0-1025-nvidia`、`linux-headers-nvidia-hwe-24.04`，**移除** held 的 `linux-nvidia-hwe-24.04` |
| 01:29 | head/02 | `update-grub` 重新生成 grub.cfg（mtime 01:30 / 01:31），新内核进入子菜单 index 0/1 |
| 01:31 / 01:32 | head / 02 / 03 | 三台重启（OTA 触发） |
| **01:38** | head/02 | 起进 `7.0.0-1019-nvidia`：`BOOT_IMAGE=/boot/vmlinuz-7.0.0-1019-nvidia`、`CmaTotal=0`、无 nvidia 模块 |
| 01:38–01:40 | head | `dsv41.service` 自动起服 → 预检 `✗ 内核 / ✗ CmaTotal / ! 驱动` → `rc=1` |
| **01:58:57** | head | watchdog 达 6 h / 3 次上限 → 写 `GIVE_UP`，此后不再自动重启 |
| **08:06:52** | head | 用户手动 `sudo systemctl start dsv41.service` → 507 ms 后 `status=1/FAILURE`（同一条预检） |
| 08:26–08:48 | — | 现场取证（只读）：内核/驱动/CMA/grub/dpkg/apt/watchdog 全链对照 |
| **08:48** | head/02 | `GRUB_DEFAULT="1>2"` → **`"1>4"`** + `update-grub`（备份 `/etc/default/grub.bak-20261110`），核对子菜单 index 4 = 6.17.0-1031 |
| 08:48:48 / 08:48:51 | 02 / 01 | 依次重启（03 不动） |
| 08:50 | 01/02 | 回线：`6.17.0-1031-nvidia` / `580.173.02` / `CmaTotal=131072 kB` |
| **08:49:24 → 08:57:11** | head | `dsv41.service` 自动起服：预检全绿 → share 2/2 → serve → **health=200 用时 467 s** |
| 08:57:43 | head | 三层验证 ②③④⑤ 全绿，**① 报 `/health 异常：000`**（见 §4 陷阱 2）→ 单元被判 failed |
| 08:58 | head | `systemctl start` 幂等跳过（"服务已在运行"）→ 单元恢复 `active (exited)` `rc=0`；删 `GIVE_UP`、清 `attempts.log`/`consecutive_failures` |
| 09:00 | 三台 | `apt-mark hold` 6.17 三件套（image / modules / nvidia-580-open） |
| 09:02 | head | `./svc.sh status`：三台 healthy、RoCE `via NET/IB 64`、`reg_mr` 0；真实请求 `7+8?` → `15` |
| 09:14–09:25 | 仓库 + head | 落地 `svc.sh` 两处判据修复（§5），head 上 `preflight` 全绿 |

## 2. 证据与获取方式（全部只读，可复现）

```bash
# 1) 结论层：unit 只跑了 507ms
systemctl status dsv41.service --no-pager -l | head -8
systemctl show dsv41.service -p Result -p ExecMainStatus -p ExecMainStatus

# 2) 预检原文（含被误报的"2 个 GPU 计算进程"）
tail -60 ~/dsv41-3xspark/systemd-dsv41.log

# 3) 内核/驱动/CMA
uname -r; cat /proc/cmdline; grep -E 'Cma(Total|Free)' /proc/meminfo; nvidia-smi; lsmod | grep -E '^nvidia'

# 4) 到底哪个内核有驱动模块
for k in 7.0.0-1019-nvidia 7.0.0-1025-nvidia 6.17.0-1031-nvidia; do
  echo -n "$k: "; find /lib/modules/$k -name 'nvidia.ko*' 2>/dev/null; done
modinfo -k 6.17.0-1031-nvidia nvidia | grep -E '^(version|filename)'

# 5) GRUB：实际生效项 + 子菜单序号
grep ^GRUB_DEFAULT /etc/default/grub
sudo grep -n 'set default' /boot/grub/grub.cfg
sudo awk '/^submenu/{s=1;next} s&&/^\tmenuentry/{i++; print i-1": "$0}' /boot/grub/grub.cfg | head

# 6) OTA 改了什么
sudo awk '/Start-Date: 2026-11-10/{p=1} p' /var/log/apt/history.log
sudo zgrep -h 'linux-modules-nvidia-580-open-7.0.0-1019' /var/log/dpkg.log* | tail -3

# 7) 自愈已经放弃
cat ~/dsv41-3xspark/state/watchdog/GIVE_UP; tail -3 ~/dsv41-3xspark/logs/watchdog.log
```

**关键对照表（08:30 实测）**

| 节点 | 内核 | 驱动 | CmaTotal | 结论 |
|---|---|---|---|---|
| fq-dgx-01 (head) | 7.0.0-1019 | 无（`lsmod` 无 nvidia） | 0 | ✗ |
| fq-dgx-02 | 7.0.0-1019 | 无 | — | ✗ |
| fq-dgx-03 | 6.17.0-1031 | 580.173.02 | 131072 | ✓ |

**grub 子菜单下标（01/02，01:30 重新生成后）**：`0/1`=1025、`2/3`=1019、**`4/5`=6.17.0-1031**、`6/7`=1029、`8/9`=6.11。
worker-03 因为没装 1025 镜像，仍是 `0/1`=1019、**`2/3`=6.17.0-1031** —— **三台的 `1>N` 不能照抄**。

## 3. 修复动作（2026-11-10 08:48–09:25）

```bash
# ① 只有 01/02 需要改：新内核插在最前，6.17 从 index 2 退到 index 4
sudo cp -a /etc/default/grub /etc/default/grub.bak-20261110
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="1>4"/' /etc/default/grub
sudo update-grub
sudo grep -n 'set default' /boot/grub/grub.cfg          # 必须看到 set default="1>4"
sudo awk '/^submenu/{s=1;next} s&&/^\tmenuentry/{i++; print i-1": "$0}' /boot/grub/grub.cfg | sed -n '5p'
#   → 4: menuentry 'DGX OS GNU/Linux, with Linux 6.17.0-1031-nvidia'

# ② 依次重启 01、02（03 不动）；切记不要一次 ssh 循环打三台（reboot 会切断连接导致静默漏掉）
ssh fq-dgx-02.local 'sudo systemctl reboot'; ssh fq-dgx-01.local 'sudo systemctl reboot'

# ③ 回线核对
uname -r                     # 6.17.0-1031-nvidia
nvidia-smi --query-gpu=driver_version --format=csv,noheader   # 580.173.02
grep -m1 CmaTotal /proc/meminfo                               # 131072 kB

# ④ head 的 dsv41.service 会开机自启（预检 → share（local 模式秒级）→ serve → 三层验证）

# ⑤ 服务健康后再清守护状态，否则 watchdog 永远不介入
rm -f ~/dsv41-3xspark/state/watchdog/GIVE_UP
: > ~/dsv41-3xspark/state/watchdog/attempts.log
echo 0 > ~/dsv41-3xspark/state/watchdog/consecutive_failures

# ⑥ 防复发：钉住已知好内核三件套（三台都要）
sudo apt-mark hold linux-image-6.17.0-1031-nvidia linux-modules-6.17.0-1031-nvidia \
                  linux-modules-nvidia-580-open-6.17.0-1031-nvidia
```

> ⚠️ **不要装** `linux-modules-nvidia-580-open-7.0.0-1025-nvidia`：它 `Depends: nvidia-kernel-common-580 (>= 580.178.04)`，
> 而 6.17 的模块是按 `580.173.02` 编译的（`nvidia-kernel-common-580` 现为 `hi` 保持状态）。装了等于把
> 6.17 的驱动配对一起弄坏 —— 这正是 [`kernel_switch2.sh`](../scripts/kernel_switch2.sh):24 当初刻意回避的包。
>
> ⚠️ **`apt-mark hold` 只是辅助**：本次 OTA 连 held 的 `linux-nvidia-hwe-24.04` 都直接移除了。
> **每次 OTA / 内核变动后，必须重新核对 grub 默认项解析到哪个内核**（`grep 'set default' /boot/grub/grub.cfg` + 子菜单序号）。

## 4. 两个把人带偏的假象（都已实测确认）

1. **"有 2 个 GPU 计算进程残留"是误报，不是现场**。
   预检用 `sudo nvidia-smi --query-compute-apps=pid ... | wc -l` 数进程（旧 `svc.sh:76`），
   而该机的 `nvidia-smi` 与驱动失联时**把报错打到 stdout**：一行错误 + 一行空行 = **2 行** →
   `wc -l = 2` → 三台里有驱动的是"0 个"，没驱动的两台都报"2 个残留"。
   复现（用假 `nvidia-smi`）：`./nvidia-smi | wc -l` → **2**，`| grep -cE '^[0-9]+$'` → **0**。
   **实际现场是真的三台都空**：`docker ps` 无引擎容器，GPU 利用率 2–5%。
   若按报错提示去"重启该机"，就会在**内核没修好**的前提下白白重启一轮，且下一轮仍失败。
2. **三层验证的 ① `/health` 有 ~40 s 无响应窗口**。
   实测 08:57:45 探到 `000`、08:58:11 恢复 `200`（此时 ②③④⑤ 全绿、三台容器 `(healthy)`）。
   单次无重试的 `curl` 把它判成失败 → `dsv41.service` 被标 `failed`（`rc=1`），
   而**服务本身是好的**。注意 `[4/5] 等待就绪` 里的 `health=200` 是成功退出后才打印的，
   所以这 40 s 窗口说明"就绪判据"与"验证判据"口径不一致。

## 5. 本次落地/未落地的变更

| 变更 | 状态 | 说明 |
|---|---|---|
| `svc.sh` GPU 进程计数改用 `grep -cE '^[0-9]+$'`，并新增 `K=` 可信位：`K=0` 时不说"有残留"，改报"nvidia-smi 报不出计算进程（驱动异常？）" | **已落地**（仓库 + head，`svc.sh` 255 行，sha256 `b6827cad…`） | 预检、`cmd_stop` 的同类计数一并改；head 上 `./svc.sh preflight` / `status` 实测全绿。可信位实测：真 smi → `1`，假失败 smi → `0`（旧逻辑同一输入数出 `2`） |
| 三层验证 ① `/health` 加 `--retry 3 --retry-delay 2 --retry-connrefused`，并新增共用 `hprobe()` | **已落地**（同上） | 用 `--retry-connrefused` 而非 `--retry-all-errors`：前者只重试"连接被拒"，不会把超时/IP 不可达也拖长（后者会让真故障多等 2×delay）。实测：关端口 6 s 内返回，活端口 1 s 返回 |
| 三台 `apt-mark hold` 6.17 三件套 | **已落地** | 见 §3 ⑥ |
| `GRUB_DEFAULT` 由位置参数改为**标题/条目 id** | **未做**（待决策） | GRUB 2.12 的 `grub-reboot --help` 明确支持 title/id + `>` 路径；但需一次重启验证，不能在服务在线时盲改 |
| `kernel_switch2.sh` 增加"选完内核后核对 grub 默认项"一步 | **未做** | 该脚本目前只打印条目 id（`kernel_switch2.sh:50`），不校验 `set default` 是否指向目标内核 |

## 6. 防误判清单（新增，与前两份事件文档并列）

- **看到 `dsv41.service` "failed" 先看它跑了多久**：`CPU: 507ms` 这类 → 死在预检，**不是**引擎问题；
  `CPU` 上千秒 → 才是 serve/验证阶段。
- **"○ 个 GPU 计算进程"必须确认 nvidia-smi 自己是否健康**：`nvidia-smi` 失败时输出打在 **stdout**，
  任何 `| wc -l` 的计数都不可信。判据先看 `nvidia-smi --query-gpu=driver_version` 是否返回版本号。
- **`/health` 刚起服后不可靠约 40 s**：判断"服务是否起来"要连续探 3 次或用 `--retry`，
  单次 `000` 不足以判失败。
- **OTA 后必查三件事**：`uname -r`、`grep 'set default' /boot/grub/grub.cfg`、`/lib/modules/<krel>` 下有没有 `nvidia.ko`。
  三者任一不符就别启服务，先修内核。
- **别把 `GIVE_UP` 忘掉**：watchdog 放弃后会**静默**（每 2 分钟只写一行日志），
  修好服务后一定要删 `state/watchdog/GIVE_UP`，否则下一次真实故障没人救。

## 7. 遗留与下一步

1. **（最高优先）把 `GRUB_DEFAULT` 从位置参数换成标题/id**，彻底消除"OTA 插新内核 → 下标漂移"；
   或者接受现状，但在 `svc.sh` / `watchdog.sh` 里加一条"当前内核 ≠ `WANT_KERNEL` 时报警到 stderr/日志显眼位置"。
2. **`svc.sh` 的 `WANT_KERNEL` 目前只覆盖 head 本机**（`svc.sh:56` 用的 `uname -r`），
   两台 worker 的内核/驱动只在 `cmd_status` 里被打印、**不参与预检判定**。
   本次正是"worker-02 内核错了"却由 head 的失败间接暴露 —— 建议把 worker 的 `uname -r`/驱动并入预检。
3. `kernel_switch2.sh` 收尾增加"核对 `set default` 指向 $KREL"的断言（只打印 id 不够）。
4. 01:58 那次 `GIVE_UP` 说明"6 h 3 次"的额度被 00:17/01:03/01:38 三轮快速耗尽；
   可考虑对"预检失败"这类**确定性失败**直接 exit 1 并显式提示"需人工"，而不是消耗自愈额度。