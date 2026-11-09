# e5-mms-patch

E5（Unisoc UMS9621）随身路由刷 e5-sleep 系列 OpenWrt 后，用来做**纯短信盒子**的用户空间补丁：
只收短信、转发到手机，不开热点、不做文件共享或代理。不碰内核、不动固件分区，配置和源件全在
`/etc/e5`（跨升级保留），由 S19 开机自愈链铺回被升级覆盖的 `/usr` 文件，卸载可完整回滚。
当前版本 **v1.0.8**。

一句话概括：把一台待机 600-900mW 乱跳、彩信显示乱码、转发丢消息、升级就失效的随身路由，
改成端到端 7 秒推送、能熄屏深睡、能自愈的短信网关。

## 这套补丁解决什么

| # | 原厂固件的问题 | 补丁做法 |
|---|---|---|
| 1 | 彩信到达通知（WAP Push）被当成普通短信解码，收件箱里是一串 `?<?` 乱码 | 识别端口 2948/2949 按 WSP Push 解析成可读通知；已存成乱码的历史消息可回填 |
| 2 | 转发失败即永久丢失：`claim` 已占用消息 ID，失败后既不重试也不再派发 | 失败入队，按 30s→6h 退避补发，投递日志持久化到 `/etc` |
| 3 | PDP 常连时基带每 26 秒唤醒一次 SIPA，待机 600-900mW 波动 | 按需拨号：平时断开、有推送才拨号，端到端 **7 秒**，醒着瞬时降到 317-325mW |
| 4 | 熄屏只关屏幕，CPU 不睡 | 深睡守护：USB 拔出满 6s、背光为 0、队列为空才写 `mem`（`deep`），短信/CP 消息可提前唤醒 |
| 5 | USB RNDIS 数据面卡死：UDC 显示 `configured` 但 `usb0` 计数不动，ping 走 WiFi 是假象 | `e5-usb-recover` 软件拔插 + S99 开机自检；严禁 `unbind musb-sprd`（会触发内核重启） |
| 6 | `/usr` 升级即被覆盖；Android 与 OpenWrt 的短信各存一份、互不可见 | `/etc/e5` 保留源件 + 开机自愈；`e5-sms-sync` 双向同步 `inbox.json` 与 `mmssms.db` |

功耗读数口径：317-325mW 是**醒着瞬时**值；平均电流按 dmesg `cc_mah` 差分估算约 41 mA / 167 mW，
属待过夜复核的推断。`charge_counter` 恒为 1、各 `capacity` 属性会因 OCV 重算瞬跳，均不能用来算放电量。

安装、验证、卸载与各模块细节见下文。

## 环境要求

- E5 类设备（Unisoc UMS9621 基带）+ 基于 `e5-sleep` 系列的 OpenWrt 固件
- 需要存在 `/usr/lib/e5/sms_pdu.py`（短信 PDU 解码器）
- 需要 `python3`（固件自带）
- 固件版本参考：`6.18.54-e5-sleep14` / `6.18.54-e5-sleep16`，理论兼容其它 e5-sleep 版本

## 安装

### 方式一：在线一条命令（推荐）

设备能连外网时，直接执行：

```sh
wget -q -O /tmp/e5-mms.sh --header='Accept: application/vnd.github.raw' \
  https://api.github.com/repos/qingchangsheng123/e5-mms-patch/contents/install.sh && sh /tmp/e5-mms.sh
```

脚本发现本地没有 `files/` 会自动下载发布包再安装。

> 为什么不用 `raw.githubusercontent.com`：这个域名在国内网络下经常被重置（实测 `Connection reset by peer`），而 `api.github.com` 和 `codeload.github.com` 通常可用。两者都失败时才需要用方式二。

### 方式二：离线

把整个仓库拷到设备（或下载 zip / tar.gz 解压后传进去），在解压出的目录里：

```sh
sh install.sh
```

### 安装时发生了什么

```
files/sms_pdu.py        ->  /etc/e5/mms/sms_pdu.py        （彩信解码器）
files/patch-forward.py  ->  /etc/e5/mms/patch-forward.py  （转发补丁）
files/backfill.py       ->  /etc/e5/mms/backfill.py       （历史回填工具）
files/install-core.sh   ->  /etc/e5/mms/install.sh        （核心安装逻辑）
files/e5-mms.init       ->  /etc/init.d/e5-mms            （开机自愈，START=19）
```

省电扩展（同样由 `install.sh` 铺好，再由 S19 自愈链维护）：

```
files/power-install.sh   ->  /etc/e5/power/install.sh
files/powersave.sh       ->  /etc/e5/power/powersave.sh
files/e5-deepsleep       ->  /etc/e5/power/e5-deepsleep      （源件，自愈时铺回 /usr/sbin）
files/e5-deepsleep.init  ->  /etc/e5/power/e5-deepsleep.init （源件，自愈时铺回 /etc/init.d）
```

然后核心安装逻辑会：

- 备份原版 `/usr/lib/e5/sms_pdu.py` 到 `/etc/e5/mms/sms_pdu.orig.py`，再用带 MMS 解码的版本覆盖；
- 备份原版 `sms-forward` 到 `/etc/e5/mms/sms-forward.orig`，再给它打上失败重试补丁；
- 重启收短信的进程（解码器只在启动时读入文件）；
- 重启转发服务。

**为什么需要开机自愈**：系统升级会重新覆盖 `/usr` 下的文件，而 `/etc/e5` 会保留。`/etc/init.d/e5-mms`（START=19）每次开机早于短信服务执行一次安装，升级后自动补回来，不用手动重装。

每次自愈的执行过程都会写进 `/etc/e5/mms/boot.log`（超过 64KB 自动截断保留后半），想看"这次开机到底补了什么"直接读它：

```sh
cat /etc/e5/mms/boot.log
```

```
[2026-11-01 22:23:06] 开机自愈开始 uptime=6s 收短信进程=0
[2026-11-01 22:23:06]   彩信解码已安装（MMS WAP Push）
[2026-11-01 22:23:07]   短信转发补丁已是最新
[2026-11-01 22:23:07] 开机自愈完成 rc=0 用时=1s 收短信进程=0（开机早期，交给系统服务拉起）
```

开机第 6 秒 S19 执行时收短信进程本来就还没起，所以前后都是 `0` 属正常；开机完成后系统服务会把它拉起来
（用 `ps w | grep '[e]5-sms-receive'` 可确认是 1 个）。手动执行 `/etc/init.d/e5-mms start` 时进程已在跑，
完成行会显示实际数量。

### 可选：回填历史乱码

装完之后，收件箱里**已经存成乱码**的彩信通知不会自动变好，需要回填一次：

```sh
sh install.sh --backfill
# 或
python3 /etc/e5/mms/backfill.py --dry    # 先看一眼会改什么
python3 /etc/e5/mms/backfill.py          # 真正写回
```

回填只改消息正文，指纹、分片、时间、已读状态、转发记录都不动，不会重复推送。

## 验证

```sh
# 解码器是否已替换（应输出 MMS_PUSH_PORTS）
grep -c MMS_PUSH_PORTS /usr/lib/e5/sms_pdu.py

# 转发补丁是否已打（应输出 e5-forward-queue-v1）
grep -c 'e5-forward-queue-v1' /usr/libexec/unisoc-modem/sms-forward

# 队列状态 / 投递记录
e5-forward status
cat /etc/unisoc-modem/forward/delivery.log

# 开机自愈每次执行干了什么（含开机秒数、执行前后收短信进程数）
cat /etc/e5/mms/boot.log
```

再收到一条彩信通知时，正文应该是：

```
【彩信】彩信通知（内容未下载）
内容地址：http://...
```

## 卸载

```sh
sh uninstall.sh
```

会还原两个原始文件、停用 `e5-mms` 开机服务、重开短信接收进程。`/etc/e5/mms` 下的备份和待重发队列不会删，确认无误后可手动 `rm -rf /etc/e5/mms`。

省电扩展独立，单独回滚：

```sh
/etc/init.d/e5-data-ondemand stop && /etc/init.d/e5-data-ondemand disable
/etc/init.d/e5-powersave stop && /etc/init.d/e5-powersave disable
/etc/e5/power/powersave.sh off     # 恢复热点与蓝牙音频
/etc/init.d/e5-deepsleep stop && /etc/init.d/e5-deepsleep disable
```

## 熄屏深睡守护（v1.0.7）

`e5-deepsleep` 只在四个条件同时满足时才挂起：**没有 `/run/e5-deepsleep.off`、USB 未插
且已连续拔出超过 6 s（`ED_USB_SETTLE`，防止拔插瞬间误判）、背光为 0、转发队列为空**。
写 `/sys/power/state` 进 `mem`（当前 `mem_sleep` 为 `[deep]`），
RTC 兜底 600 s，队列有活时缩到 30 s；CP 的 `smsg` 消息会提前唤醒，醒来该收的短信、该发的
转发都照常跑完，再进入下一轮。

```sh
/etc/init.d/e5-deepsleep status          # 服务状态
touch /run/e5-deepsleep.off              # 临时禁睡（不重启服务）
cat /root/e5-deepsleep.log               # 每轮 slept / ovh / nap / 唤醒源
/etc/e5/power/powersave.sh status       # 热点、蓝牙、音频、WiFi 链路
```

开机省电模式默认关热点并 down 掉 `wlan0`：实测 `wifi down` 会让 wcn 驱动半死
（MPM wakelock 每轮 0.78 s、挂起 EBUSY），所以一律用 `ip link set wlan0 down`。
临时要开 WiFi：

```sh
/etc/e5/power/powersave.sh wlan-on
/etc/e5/power/powersave.sh wlan-off
```

> **注意**：开热点会触发 netifd 重载，**USB RNDIS 会断开**，届时改用串口或重新拔插 USB。
> 这台设备默认只做短信转发、不做热点，所以常关是常态。
> 需要远程调试时，开热点后主机连接 `E5-OpenWrt` 会拿到 `192.168.9.100`，可直接 SSH 到
> `192.168.9.1`（USB 通道不通时的备用路径）。

90 分钟实机窗口（未插线、wlan0 down、日志写 tmpfs）：107 轮、占空比 94.42%、挂起失败 0，
唤醒源 100% `pscp-5:smsg-5-6`。剔除 >60 s 的长睡轮后短睡段占空比 74.97%。

**平均电流约 41 mA / 167 mW（B 级，待过夜复核）**：按 `cc_mah` 连续 7.7 h 下降 317 mAh 估算。
`charge_counter` 在本机恒为 1（无效属性）；`battery/capacity` 与 `sc27xx-fgu/capacity`
都会因开路电压重算**瞬间跳变**（实测 100%→43%、39.6%→87.9%），不能用来算放电量。
早先用 `charge_counter` 差分得到的 10.27 mA / 12.5 天已作废。
若复核后仍是 40 mA 量级，说明深睡只压住了 AP，CP/modem 常开才是主要耗电源。
另有一次 `time.sleep(0.5)` 被拉长到 3 s 的 AP 侧调度问题在查。

## USB 数据面卡死的自愈（v1.0.8）

故障特征很有迷惑性：设备侧 UDC `state=configured`、`usb0` UP、`carrier=1`，Windows 侧
「以太网 3」也已连接且有 IP，但 **`usb0` 的收发计数完全不动**。此时 ping 看着能通，是因为
USB 与 WiFi 同在 `192.168.9.0/24`，Windows 挑了 WiFi 应答；TCP/ssh 才暴露真相。

判定与恢复：

```sh
cat /sys/class/net/usb0/statistics/rx_packets   # 打几个包后计数不动 = 数据面卡死
/usr/sbin/e5-usb-recover                        # UDC 软件拔插，约 6 s 后恢复
/usr/sbin/e5-usb-recover status                 # 只读体检，不动硬件
```

底层动作是 `soft_connect` 写 `disconnect` 再写 `connect`，主机重新枚举，不必重启设备。
**严禁 `echo 64a00000.usb > /sys/bus/platform/drivers/musb-sprd/unbind`**：实测会直接触发
内核重启。开机自检 `e5-usb-guard`（S99）在插线且状态异常或 ping 不通主机时自动调用恢复工具。

源件在 `/etc/e5/usb/`，由 `/etc/e5/power/install.sh` 第 4 段随 S19 自愈链铺回，
固件升级不会丢。`/root/pm-test.sh` 是过夜功耗测试脚本（一次性用途，v5），测试期间会临时
停掉三个周期性唤醒源并在结束时恢复。采样用 wall 时间闸门而非 `sleep`，因此 AP 深睡挂起时
不会漏采，也不额外增加唤醒源；收尾会打印 `SAMPLES n / maxgap / overshoot` 供核对。

## 省电：按需蜂窝数据

`sleep16` 上有个容易忽略的耗电点：**只要数据连接（PDP）保持激活，基带每约 26 秒会唤醒一次
SIPA 数据加速器，每次活约 10 秒、功耗 900mW**。实测这台设备：

| 状态 | 功耗 |
|---|---|
| 数据常连 | 600-900mW 波动 |
| 数据断开 | **317-325mW**（±30mW） |

而拨号只要 6 秒，短信走信令通道、与数据连接无关。所以默认改成"平时断开、要推送才拨号"：

```sh
/etc/e5/power/data-ondemand.sh status   # 数据连接 / 待发队列 / 守护进程
/etc/e5/power/data-ondemand.sh up       # 手动拨号
/etc/e5/power/data-ondemand.sh down     # 手动断开
```

- 短信到达 → 投递失败入队 → 守护 3 秒内发现 → 拨号 3-6 秒 → 强制补发，实测 **7 秒**
  （从设备确知这条短信，到 webhook 返回 200）；运营商短信中心到达设备的延迟另算
- 队列空后保持 90 秒才挂断，多条连发只拨一次
- 拨号失败退避 90 秒
- 日志：`/etc/e5/power/data-ondemand.log`，含"最早一条 Xs 前入队"，便于核算端到端延迟

不想牺牲推送实时性可以常连：

```sh
/etc/init.d/e5-data-ondemand disable    # 不再自动挂断
```

## 双系统：OpenWrt 与 Android 短信互通

E5 的 Android 与 OpenWrt 不会同时运行（`e5-next-boot` 决定启动哪一个），但共用同一块
userdata，短信本来各存一份：OpenWrt 在 `/etc/e5-sms/inbox.json`，Android 在 TelephonyProvider
的 `mmssms.db`。`e5-sms-sync` 让两边互相可见。

```sh
e5-sms-sync status                     # 两侧条数、已同步数、挂载状态、上次运行
e5-sms-sync run                        # 立即同步一次
e5-sms-sync run --dry-run --verbose    # 只看差异，不动数据
```

| 方向 | 写入位置 | 标记 | 是否触发转发 |
|---|---|---|---|
| OpenWrt → Android | `sms` 表 | `creator='e5-sync'` | — |
| Android → OpenWrt | `inbox.json` | `source='android'`、`identity='android'` | **不转发** |

- 只在 Android 未运行时写数据库；写前把 `/mnt/e5-data` 临时改成 rw，写完恢复 ro
- 每次真正写入前备份 `mmssms.db` 到 `/etc/e5/sms-sync/backup/`（保留 3 份）
- 开机跑一次，之后 cron 每 2 分钟增量；日志 `/etc/e5/sms-sync/sync.log`
- 升级固件后无需手动恢复：`/etc/e5/sms-sync` 已加入 `e5-mms` 的开机自愈扩展列表
- 卸载：`sh /etc/e5/sms-sync/uninstall.sh`（已写入 Android 的短信需在 Android 侧自行删除）

已知限制：Android 侧的全文搜索索引（`words` 表）不会为同步进来的短信补建；中文本来也不分词，
列表与会话查看不受影响。

## 两个问题的根因

### 1. 彩信通知乱码

彩信到达时运营商发的是 **WAP Push**，不是普通短信：UDH 里带端口寻址（destination port **2948**，MMS notification），正文是 WSP Push PDU，content-type `0xaf` = `application/vnd.wap.mms-message`。

原版解码器只看 UDH 里的分片信息，忽略端口寻址，于是把整条二进制 PDU 当成短信文本按 latin1 解，得到的就是乱码。

补丁做的是：识别 2948/2949 端口 → 按 WSP Push 结构逐字段解析（Message-Type、From、Content-Location、Subject、Message-Size）→ 渲染成一条人类可读的通知。解析不出来时退回"正文里搜 http 链接"的容错路径。

注意：中国移动的加密彩信通知里**只有内容地址**，没有主题和大小，所以那条通知就只有地址一行，这是上游协议本身如此，不是解析缺失。

### 2. 转发失败即丢失

原版 `sms-forward` 的流程是：事件到来 → `claim` 占住消息 ID → 投递一次 → 失败就记一条结果。问题在于 `claim` 已经把 ID 烧进去了，失败后既不会重试，ID 也再不会被派发，消息等于永久蒸发。另外：

- 投递结果只看 HTTP 状态码，而 pushplus 这类服务 token 无效时仍返回 `HTTP 200`，body 里才是 `{"code":903}` —— 看起来"成功"，其实没发出去；
- 投递历史存在 `/run`（tmpfs），重启即丢，事后无从查证。

补丁不改原有投递逻辑，只加三件事：

1. 投递失败且属于可重试类型（`delivery_failed` / `chat_not_found` 之外的网络、服务端拒绝、DNS 失败等）时，把消息写进队列目录；
2. 常驻 worker 按 **30s / 2m / 10m / 30m / 2h / 6h** 退避补发，第 7 次仍失败才放弃；
3. 补发过程写 `/etc/unisoc-modem/forward/delivery.log`（持久化，超 200KB 自动截断）。

打补丁是幂等且保守的：已打过直接退出；上游脚本改版导致锚点对不上就**放弃并说明原因**，绝不写半成品进去。

## 目录结构

```
install.sh              一键安装 / 升级
uninstall.sh            卸载回滚
package.sh              打成可分发 tar.gz
VERSION                 版本号
files/
  sms_pdu.py            带 MMS 解码的短信解码器（替换 /usr/lib/e5/sms_pdu.py）
  patch-forward.py      给 sms-forward 打重试队列补丁的脚本
  backfill.py           历史乱码彩信回填
  install-core.sh       核心安装逻辑（装成 /etc/e5/mms/install.sh）
  e5-mms.init           开机自愈服务
  power-install.sh      省电扩展自愈安装（含深睡守护 + USB 自愈，共 5 段）
  powersave.sh          省电开关 / WiFi 手动开关
  e5-deepsleep          深睡守护（Python）
  e5-deepsleep.init     深睡守护 procd 服务
  data-ondemand.sh      按需蜂窝数据
  e5-usb-recover        USB gadget 软件拔插复位
  e5-usb-guard-check    开机自检逻辑
  e5-usb-guard.init     开机自检服务（S99/K10）
  pm-test.sh            过夜功耗测试 v5（源件放 /etc/e5/usb/，装到 /root）
```

## 打包分发

```sh
sh package.sh
# 产出 dist/e5-mms-patch-<version>.tar.gz 和对应的 .sha256
```

## 已知限制

- 只处理**彩信到达通知**，不下载彩信内容。要取图需要额外的 MM1 下载流程（走运营商 MMSC），本补丁不涉及。
- 加密通知只有 URL，且该 URL 通常需要手机侧鉴权，直接打开多半失败。
- 依赖上游 `sms_pdu.py` / `sms-forward` 的现有结构；固件大改版后 `patch-forward.py` 可能报"锚点对不上"，此时需要跟进适配。
- 只支持单个 modem 实例（`Modem/0`）。
- 深睡守护的真实平均功耗未测（见上节），短睡段仍被 CP `smsg-5-6` 高频簇打断，约 8-10 s 醒一次；
  静默期可连睡 600 s，整轮占空比取决于两种状态的占比。
- 开热点会断开 USB RNDIS；若数据面卡死，用 `/usr/sbin/e5-usb-recover` 软件拔插恢复，
  不要 `unbind musb-sprd`。深睡期间 SSH 不可达，调试请插线或用串口。
- 主机同时连着 USB 与 `E5-OpenWrt` 热点时，两者同在 `192.168.9.0/24`，Windows 按接口度量
  选路；判 USB 是否真的通，必须看 `usb0` 计数增量或做 TCP 连接，不能只看 ping。

## 许可

MIT
