# 更新记录

最终版本，从一台实机（E5 / UMS9621 / `6.18.54-e5-sleep16`）的部署中逐步修正而来。
早期迭代号（1.0.0 / 1.0.1 / 1.0.2）已从仓库撤销，其修复内容都并入本版本，不再单独发布。

## 1.0.10 — 2026-11-10

信息屏一轮审查（10:20–10:27）后修掉 4 项显示/噪音缺陷，并把「短信转发」做成屏上
可用的面板。核心链路（收短信 → 解码 → webhook → 退避重试）未改动。

### 修复：熄屏久了，亮屏那一瞬间信号格是空的

- `t551m-sim-status` 熄屏时 `INTERVAL_DARK=60`（省电，不每 5 s 敲基带），而
  `api.uc` 的 `sim_status()` 只认 15 s 内的快照，超时就返回空 `signal`；
- `card_modem()` 里 `quality` 又被硬编码成 `null`（防止借副卡的信号），前端两条
  兜底同时失效，于是亮屏后必然 0 格 + 制式 `--`，直到下一次采样（≤5 s）才恢复。
- 改为：过期快照保留最后已知的 `present/registration/tech/signal`，只标
  `stale: true`；`app.js` 用最后一次 `rsrp` 折算格数并把信号格降到 55% 透明度，
  `rsrp` 缺失才回落 `m.quality`。**零额外功耗**（不加快采样）。
- 注入验证：把 `/run/t551m-sims.json` 的时间戳改到 120 s 前，`/api/status` 仍返回
  `rsrp=-95 / quality=62.5 / stale=true`，不再是空对象。

### 修复：8089 通道从来没部署过，却每 3 秒重连一次

- `transport.js` 连 `ws://127.0.0.1:8089/rpc`、`calls.js` 连 `:8089/events`，实际只有
  8088 的 API 实例在监听；原生 `fetch` 一直兜着，所以功能不坏，代价是 console 每
  3–4 s 一条 `CONNECTION REFUSED`（实测 17 秒内 6 条）。
- `transport.js` 改为原生 fetch 直通（该 shim 已无存在意义）；`calls.js` 的 SSE 首次
  失败就 `close()`，交给已有轮询兜底。重启后同一 session 不再出现 8089 错误。

### 新增：信息屏「应用 → 短信转发」面板

原来屏上能看到短信收发，看不到「转发到哪、有没有发出去、失败后有没有重试」。
新增 `forward` 插件（`/etc/e5-infoscreen/plugins/forward`，`plugin link` 挂到 web root）：

- 状态：开关、目标主机（**只给 host**，不下发带 token 的 `webhook_body`）、队列
  `pending/limit`、最近 5 条投递（读 `delivery.log`，把 `invalid_destination` 之类
  内部代号翻成中文）；
- 操作：开关（`POST /toggle`）、测试发送（`test-start`）、重试队列（`queue-retry` 放后台）；
- 写配置走 `e5-forward set`，但它**是全量覆盖**，所以后端先 `get` 再把 22 个字段
  展平回传，`smtp_password` / `dingtalk_secret` 不回传（脚本缺省时保留原值）。
  实测回写后 `config.json` 全字段一致、`webhook_body` 长度不变。

### 顺带

- 热点省电插件的 `mode` 默认值由 `radio`（关蜂窝，短信一起断）改为 `data`（只断数据），
  `backend.uc` 的兜底默认值同步；已配置过的设备不受影响。
- `patch-screen.py` 幂等：按 marker 跳过已打过的文件，锚点对不上（原厂换版）就原样
  不动并打印原因；`--revert` 从 `/root/e5-backup/screen` 恢复。

### 实测：v1.0.10 生产配置 4.90 h，21.44 mA

拔线 12:04:45–16:58:40（`DUR=17100 STEP=120`），静默窗口内跑完整生产配置：
`cc_mah -295 → -400` = 105 mAh → **21.44 mA / 82.6 mW**，燃料计 84.7%→81.0% 交叉印证；
占空比 98.8%、63 轮、醒 218.8 s、挂起失败 0。同窗 11-09（v1.0.8）为 22.85 mA / 90.3 mW，
本版低 6.2%。盯的就是 v1.0.9 新增的两个唤醒源（`modem-guard` 180 s、`sms-sync` cron 2 min）：
**没有抬高均值** —— 醒着的时间反而从 639 s 降到 219 s，唤醒标记 38/39 是 CP 的
`pscp-5:smsg-5-6+N`，与看门狗、cron 无关；`modem-guard.log` 全程 0 字节（零恢复动作）。
顺带在窗口内收到真短信一条：首投 `invalid_destination`，14 s 后第 2 次尝试补发成功。

## 1.0.9 — 2026-11-10

全项目静态审查（11-09 21:55）确认的 9 项 A 级缺陷集中修复，并补上过夜实测数据。
运行时行为只有一处对外可见变化：**全新安装现在真的会装上双系统短信同步**。

### 修复：基带停在 CFUN=0 时没人管，短信全丢

2026-11-10 08:35 实测：`AT+CFUN?` 回 `+CFUN: 0`、`AT+CSQ` 回 `0,99`、`AT+CREG?` 未注册，
而 `mmcli` 仍报 `state=connected / reg=home / 中国移动 / 5GNR` —— **ModemManager 的
`registration-state` 是缓存值，会骗过任何只看它的判断**。表现就是短信一条都进不来，
而转发链路（收 → 解码 → webhook → 退避重试）完全正常。恢复射频后 1 分钟内历史短信即
进箱并投递成功。

设备上本来就有 `/etc/e5/modem-guard` 这套看门狗，代码注释里甚至写了这个已知故障，
但 `/etc/init.d` 没有链接、`/etc/rc.d` 没有启动项、进程不存在，日志停在 11-06，等于没有。

- 新增 `files/modem-guard/` 四件，`install.sh` 铺到 `/etc/e5/modem-guard`，由 S19 自愈链装回；
- 在 `judge()` 之外每轮先做一次 **AT 层射频校验**（`AT+CFUN?`），拿到非 1 直接恢复，
  不再依赖 ModemManager 的注册状态；
- `rf_restore()` 分级处理：`AT+CFUN=1` → MM 丢对象则重启 MM → `state=disabled` 则
  `mmcli --enable` → bearer 掉了补一次 `ifup wan`；
- `INTERVAL` 60 → 180 s（每轮多一条 AT，60 s 会把深睡窗口切碎）、`HEARTBEAT=0`，
  并修掉「配置写 `HEARTBEAT=0` 但实现仍每轮写心跳」的缺陷。
- 实测（注入 `AT+CFUN=0`）：看门狗在下一轮检测到射频关闭并自行恢复，无需人工介入。

### 修复：sms-sync 的 cron 没有重叠保护

`*/2` 每两分钟起一次 `sms-sync.py run`，单次若因 Android 侧卡住超过 2 分钟，crond 会持续
报 `process already running`。cron 行加 `flock -n /tmp/sms-sync.lock`，重叠时新实例直接退出，
不再堆积。

### 修复：发布包不含 sms-sync 四件（最严重）

`install.sh` 与 `files/` 里从来没有 `sms-sync`，只有 `install-core.sh` 的扩展循环会去
`/etc/e5/sms-sync` 找 `install.sh`，而该目录仅在本机手工部署过。结果是 README、CHANGELOG、
GitHub About 与 release 正文都在宣传「双系统短信互通」，全新安装（含在线一条命令）却拿不到。

- 新增 `files/sms-sync/`：`sms-sync.py` / `install.sh` / `e5-sms-sync.init` / `uninstall.sh`；
- `install.sh` 部署到 `/etc/e5/sms-sync`，由 S19 自愈链执行它的 `install.sh`；
- `package.sh` 补上子目录的可执行权限。

### 修复：按需数据 stop 的语义反了

`e5-data-ondemand.init` 的 `stop_service` 调的是 `data-ondemand.sh up` —— 停服务反而拨号，
且守护已停、再没人挂断，`stop && disable` 之后整机回到 600-900 mW 常连态。
改为清 `hold` 标记 + `down` 挂断。短信走信令通道，与 PDP 无关，断开不影响收发。

### 修复：卸载回滚不完整

原来只还原解码器/转发器、停 `e5-mms` / `usb-guard` / `deepsleep`；`e5-data-ondemand`、
`e5-powersave`、`e5-sms-sync` 的自启与 cron 都留着，`powersave.sh on` 删掉的 rc.d 链接
与 uci 也没人恢复。现按顺序补齐：先 `powersave.sh off` 恢复热点/蓝牙/音频，再撤 sms-sync
的 cron 与服务，最后停按需数据并挂断。

### 修复：USB 自检不该用 ping 判数据面

设备与主机同在 `192.168.9.0/24` 时内核会经 wlan 选路，ping 通只证明 WiFi 通 —— 恰恰掩盖
USB 数据面已死，与项目铁律「同网段 ping 是假象」冲突。`e5-usb-guard-check` 改读
`usb0/statistics/rx_packets` 增量：6 s 不动就主动发一次探测，仍不动才软件拔插。
`e5-usb-recover` 的 mkdir 锁加 5 分钟陈旧清理（原来被 `kill -9` 后锁永久残留，
自检会一直跳过恢复）。

### 修复：队列 ID 同秒冲突与隐藏临时文件

`patch-forward.py` 用 `$(date +%s).$$` 做队列 ID，同一秒两条短信（双卡并发、运营商补发）
会撞名，后一条覆盖前一条 → 直接丢消息。改为撞名递增序号。重写队列条目时用的
`<id>.tmp.<pid>` 是非隐藏名，会被其他进程的 glob 当成待发消息读到半截，改成隐藏名。
`data-ondemand.sh` 的 `qlen` 原来用 `ls -A`，把隐藏临时文件算进队列，导致队列空着也反复
拨号，改为 `ls -1`。

### 修复：发布与备份脚本

- `release_final.py`：同名资产存在时原来直接 `continue`，重打包会留下旧包而正文 sha256
  是新包的。改为先删旧资产再上传。
- `backup-e5.sh`：md5 清单补 `e5-deepsleep` / `e5-usb-*` / `pm-test.sh` / `sms-sync.py`；
  rc.d 过滤补 `deepsleep` / `usb-guard` / `sms-sync`；输出从 `/tmp`（tmpfs，重启即失）
  改到 `/root/e5-backup`。
- `publish.py`（依赖已不存在的 `CODEBUDDY_MCP_CONFIG`、仓库路径写错）移到 `_legacy/`。

### 修订：README 功耗口径与 #8 说明

「41 mA / 167 mW，待过夜复核」换成实测：白天 22.85 mA / 90.3 mW（5.6 天）、
夜间 39.07 mA / 151.8 mW（3.3 天），并说明 21:30 的转折与 CP `smsg` 停止同轮次。
`time.sleep(0.5)` 被拉长到 3 s 的旧疑问也解释清楚了：挂起期间 `CLOCK_MONOTONIC` 不走，
与 v5 采样修复是同一个根因，不是 AP 调度问题。

## 1.0.8 — 2026-11-09

纯闭环版本，核心逻辑（彩信解码、转发重试、深睡守护）一行未改。

### 新增：USB gadget 自愈工具并纳入开机自愈链

现场出现过一次「UDC `state=configured`、`usb0` UP、`carrier=1`，但 `usb0` 收发计数一动不动」
的 RNDIS 数据面卡死。此时主机侧 ping 看似能通，其实是同网段的 WiFi 在应答，极易误判。
复位手段是 UDC 软件拔插（`soft_connect` 写 `disconnect` 再写 `connect`），
不需要重启、不需要动 PHY，更不能用 `unbind musb-sprd`（实测直接导致内核重启）。

- `/usr/sbin/e5-usb-recover`：软件拔插 + 必要的 UDC 补绑 + `usb0` 入桥，遵守厂商 watch 的
  `/tmp/run/e5-usb-reset/lock` 互斥锁。
- `/etc/init.d/e5-usb-guard`（S99/K10，默认启用）+ `/usr/sbin/e5-usb-guard-check`：开机 25 s
  自检，只在插线且状态不对或 ping 不通主机时动手，失败不影响系统。厂商 `e5-usb-watch`
  在 `configured` 时直接跳过，两者互补而非重复。
- `/root/pm-test.sh`：过夜功耗测试，采样直接写 `/root` 并定期 sync，不依赖 tmpfs；
  测试开跑时临时停掉三个常驻唤醒源（`e5-powersam` / `powermon` / cron `rebind.sh`），
  结束或异常退出自动恢复，开机还有一次 crontab 标记回滚兜底。

源件放 `/etc/e5/usb/`，由 `/etc/e5/power/install.sh` 第 4 段在开机（S19 自愈链）铺回
`/usr/sbin`、`/etc/init.d` 与 `/root`；`backup-e5.sh` 补齐了对应抓取项与 md5 校验。
**v1.0.7 的缺口**：这 4 个文件当时只在设备上，升级后 `S99e5-usb-guard` 会指向空文件。

### 修订：功耗测量口径

`battery/charge_counter` 在这台设备上恒为 1（无效属性），`battery/capacity` 与
`sc27xx-fgu/capacity` 都会因 OCV 重算瞬间跳变（实测 100%→43%、39.6%→87.9%）。
一律改用内核 `sprd-fgu` 打印的累计库仑计 `cc_mah` 做差分，且只在同一次连续开机区间内有效。
测试脚本 v3/v4 已按此改；v1.0.7 README 里"平均电流未测"的说法同步更新为
8 小时实机约 **41 mA / 167 mW**（B 级，待过夜复核）。

### 修订：项目简介与发布资产（当日 11:15）

功能代码一行未改，只重写对外介绍并重新打包，设备侧无需重装。

- 仓库 About 简介改为覆盖 1.0.8 全部能力：彩信解码、转发重试、按需拨号 7 秒推送、
  熄屏深睡、USB RNDIS 自愈、双系统短信互通；topics 补 `deep-sleep`、`sms-gateway`。
- README 首页由 5 条问题清单改成 6 行「原厂问题 / 补丁做法」能力表，并写明功耗读数口径：
  317-325mW 是醒着瞬时值，41 mA / 167 mW 属 B 级待复核，`charge_counter` 与各
  `capacity` 属性均不能用来算放电量。
- Release 正文开头同步，并附重新打包后的两个资产 sha256；tar.gz / zip 内 README 与
  CHANGELOG 一并更新。版本号仍为 **1.0.8**，唯一 tag / release 不变。

### 修订：#8 采样间隔失效（当日 17:20，`pm-test.sh` v4 → v5）

只改测试脚本，设备运行时功能（彩信 / 转发 / 深睡 / USB 自愈）一行未动。

- **现象**：`sleep "$STEP"` 基于 `CLOCK_MONOTONIC`，AP 挂进 deep 时定时器不推进，
  而 `date +%s`（`CLOCK_REALTIME`）照常走。11-09 下午白班 5.04 h 实测 120 s 的 STEP
  被拉长到 1069–5652 s（8.9–47.1 倍），只采到 8 个点（设计 150 个），
  `DUR` 到点后还延迟 146 s 才收尾。此前记为「`sleep(0.5)` 偶发拉长到 3 s」的 #8 即此机理。
- **修法**：改成 1 s 短轮询 + wall 时间闸门，只有跨过下一个采样点才 `sample`。
  脚本**不主动唤醒系统**，搭深睡守护唤醒的便车，因此零新增唤醒源；
  实际间隔约为守护唤醒周期的整数倍。新增 `POLL` 参数（默认 1），深睡跨过多个 STEP
  时不补历史点、从当前时刻重新对齐。
- **诊断**：收尾写 `SAMPLES n=… maxgap=…s overshoot=…` 并进 `e5-pmtest.done`，
  一眼可判修复是否生效；`sync` 由每 10 条改为每 30 条，避免采样变密后频繁刷 ext4 journal。
- **影响**：`cc_mah` 是累计量，用 wall 真实时间差分 / 回归仍成立，
  下午轮 22.85 mA / 90.3 mW 的结论不变，修复只提升分段分辨率。
  版本号仍为 **1.0.8**，唯一 tag / release 不变，两个资产重新打包。

## 1.0.7 — 2026-11-08

### 新增：熄屏深睡守护（默认启用）

`e5-deepsleep` 在 **熄屏 + 未插线 + 转发队列为空** 时用 RTC 兜底把 AP 循环挂进 `mem`（deep），
CP 消息（`smsg`）提前唤醒后正常完成短信接收与转发，然后立刻再睡。门禁任一不满足就退回普通待机，
插线调试不受影响。

- 源件 `/etc/e5/power/e5-deepsleep` + `e5-deepsleep.init`；由 `e5-mms` 的 S19 自愈链铺回
  `/usr/sbin` 与 `/etc/init.d`，S99 自动拉起，固件升级后无需手动重装。
- 开机省电模式默认关热点并 down 掉 `wlan0` 链路（用 `ip link set`，**不用 `wifi down`**：
  后者会让 wcn 驱动半死、挂起 EBUSY）。手动开关 `powersave.sh wlan-on|wlan-off`。
- 90 分钟实机窗口：107 轮 / 占空比 94.42% / 挂起失败 0，唤醒源 100% `pscp-5:smsg-5-6`。

### 修订：USB 拔出稳定期（当日 22:53）

开机自愈实测通过（S19 铺回源件、S99 拉起、守护 running+enabled）。同时抓到一个真实故障：
**拔插 USB 的瞬间** `usb/online` 会短暂读到 0，守护立刻 armed 并写 `mem`，插线回来时
musb-sprd 处于 device 模式拒绝挂起（EBUSY），USB gadget 状态错乱，主机侧表现为 RNDIS 网卡、
IPv4 栈与串口半枚举。

修复：`gate()` 新增 `ED_USB_SETTLE`（默认 **6 s**），要求 `usb/online` 连续为 0 超过该时长
才允许进入休眠循环。快速拔插不再误判，真正拔线长期使用只多等约 6 s。可用
`ED_USB_SETTLE=0` 关闭（测试用途）。生产文件与源件 md5 `dc1d2234`。

### 已知待办（不阻塞使用）

- **真实平均电流未测出**。此前用 `charge_counter` 差分算的 10.27 mA / 12.5 天已作废：
  该值是电量计按开路电压估算的 0.1% 步进，拔线后回落到稳态点就不再变化，不是库仑计。
  需过夜稳定段或外部电流表重测。
- 单次 `time.sleep(0.5)` 偶发被拉长到 3 s（约 31% 轮次），AP 侧调度层，正在定位。
- 开热点（`wlan-on`）会触发 netifd 重载，**USB RNDIS 会断开**，需串口操作或重新拔插 USB。

## 1.0.6 — 2026-11-07

### 新增：OpenWrt 与 Android 双系统短信互通

E5 的 OpenWrt 与 Android 是两套**互斥**的系统（`e5-next-boot` 决定启动哪一个），共用同一块
userdata。短信本来各存一份：OpenWrt 在 `/etc/e5-sms/inbox.json`，Android 在 TelephonyProvider
的 `mmssms.db`。切到另一边就看不到另一边的短信。

新增 `e5-sms-sync`：

- **双向**：Android 的新短信 → inbox（标 `source=android`，**不触发转发**）；inbox 里未同步的
  → `mmssms.db`（标 `creator=e5-sync`）。
- **指纹去重 + 来源标记**，两个方向不会互相回环。实测第二次运行 0/0。
- 只在 Android 未运行时写库；写前把 `/mnt/e5-data` 临时 `remount,rw`，写完恢复 `ro`。
- 每次真正写入前备份 `mmssms.db` 到 `/etc/e5/sms-sync/backup/`（保留 3 份）。
- 开机跑一次（S99），之后 cron 每 2 分钟增量；日志 `/etc/e5/sms-sync/sync.log`。

实测：73 条历史短信一次性写入 Android，17 个会话、时间与未读状态正确、无空正文、无孤儿会话；
反向插入一条测试短信后，OpenWrt 收件箱立即出现且不回写数据库。

### 变更：自愈扩展列表

`files/install-core.sh` 的扩展目录从 3 个增至 4 个（新增 `/etc/e5/sms-sync`），
升级后开机会自动重装同步服务、cron 与开机链接。

## 1.0.5 — 2026-11-06

### 修：按需拨号下首条推送延迟 31 秒

按需拨号上线后实测：设备确知短信 → webhook 成功要 **31 秒**，而拨号本身只占 4 秒。
时间线（真实日志）：

```
21:59:01  投递失败，进入队列（next = now + 30，第一次退避）
21:59:04  拨号
21:59:08  拨通
21:59:32  才补发成功   ← 中间 24 秒纯等退避
```

原因是队列项的 `next` 在断网时就写成了 `now + 30`，网络一通这些计时就没有意义了，
但 `queue-retry` 仍按 `next` 门禁跳过。改法：

- 转发器补丁升到 v2：`drain_queue` 支持 `MU300_FORCE_RETRY=1` 跳过 `next` 门禁；
- `data-ondemand` 只在"这一轮真的拨了号"时带这个变量，不滥用、不额外消耗重试次数；
- 轮询间隔 5s → 3s；
- 日志多记"最早一条 Xs 前入队"，端到端延迟可直接核算。

实测结果：**22:17:55 入队 → 22:17:57 拨号 → 22:18:00 拨通 → 22:18:02 补发成功（http 200）**，
设备侧 7 秒。日志出现"已强制补发（跳过退避）"。

补丁从 v1 升级时用 `/etc/e5/mms/sms-forward.orig` 重新打，不在旧补丁上叠加；
仅当目标文件是上游原版时才刷新这份回滚备份。

## 1.0.4 — 2026-11-06

### 新增：按需蜂窝数据（实测省 63% 功耗）

升级到 `sleep16` 后实测功耗从之前的 291-310mW 涨到 600-900mW 波动。逐项排查（停信息屏、
限 CPU 频率、停蓝牙/音频/HFP、停 wpad）后定位到根因：

> **只要 PDP（数据连接）保持激活，基带 CP 每约 26 秒会通过 `smsg` 唤醒 SIPA 数据加速器，
> 每次活跃约 10 秒、功耗 900mW。** 这是驱动层行为，用户态关不掉。

而实测断开数据后功耗稳定 **283mW**（波动 ±30mW），拨号只要 **6 秒**。
短信走信令通道（NAS），与 PDP 无关，断开数据不影响收短信。

于是加了 `e5-data-ondemand` 守护：平时断开 `wan`，一旦转发队列里有待补发的短信就拨号、
补发、再挂断。

| 状态 | 实测功耗 |
|---|---|
| sleep16 默认（数据常连） | 600-900mW（波动大，均值约 700mW） |
| 按需拨号（数据断开） | **317-325mW**（波动 ±30mW） |
| 升级前 sleep14 | 291-310mW |

- 延迟：短信到达 → 投递失败入队 → 守护 5 秒内发现 → 拨号 6 秒 → 补发，约 **15-20 秒**
  （实测为 31 秒，多出的部分是队列退避白等，已在 1.0.5 修掉，降到 7 秒）
- 队列空后再保持 90 秒才挂断，连到多条短信只拨一次
- 拨号失败退避 90 秒，避免弱信号下反复拨号耗电
- 日志：`/etc/e5/power/data-ondemand.log`
- 手动拨号后不会被自动挂断：`up` 会留一个保持标记，直到 `down` 或重启
- 手动控制：`/etc/e5/power/data-ondemand.sh {status|up|down|once}`

### 新增：开机应用省电配置

`/etc/init.d/e5-powersave`（START=98，在 S19 自愈之后）每次开机执行
`/etc/e5/power/powersave.sh on`：

- 关 WiFi 热点（用固件自带的 `hotspot off`）
- 停蓝牙 / 音频 / PulseAudio / **e5-hfp**（免提通话服务，实测占 12% CPU 且会周期性重试）
- `sleep16` 上 `e5-bt` 的 `stop` 会在 `bluetoothctl` 上卡死（bluetoothd 已停，D-Bus 无响应），
  所以改为直接删 `/etc/rc.d` 链接 + kill 残留，不用 `init stop`
- 想恢复热点：`/etc/e5/power/powersave.sh off`，再 `/etc/init.d/e5-powersave disable`

### 自愈链扩展

`install-core.sh` 的扩展列表加入 `/etc/e5/power`，系统升级清掉 `/etc/init.d` 下的自建服务后，
下次开机会自动把 `e5-data-ondemand` / `e5-powersave` 的文件和自启链接补回来。

### 注意

`sleep16` 的深度休眠（39mW 量级）在 **SD 卡启动**时被固件禁用（注释写明：SD 卡安装从休眠
唤醒不了），插着 USB 也不休眠。想再降一个数量级需要把系统装到内置存储（`--data`）。

## 1.0.3 — 2026-11-01

### 新增：开机自愈可观测性

此前开机自愈服务（`S19`）是 `>/dev/null 2>&1` 全静默的：想知道"固件升级后补丁到底补回来没有"，
只能临时插桩（把 `install.sh` 换成包装脚本、重启、取日志、再还原），过程繁琐且依赖手工。

现在每次执行都把过程写进 `/etc/e5/mms/boot.log`：

```
[2026-11-01 22:23:06] 开机自愈开始 uptime=6s 收短信进程=0
[2026-11-01 22:23:06]   彩信解码已安装（MMS WAP Push）
[2026-11-01 22:23:07]   短信转发补丁已是最新
[2026-11-01 22:23:07]   扩展 usb-rndis 已就位
[2026-11-01 22:23:07]   扩展 maintenance 已就位
[2026-11-01 22:23:07] 开机自愈完成 rc=0 用时=1s 收短信进程=0（开机早期，交给系统服务拉起）
```

- 记录项：执行时刻、开机秒数、执行前后收短信进程数、安装脚本每一条输出、退出码、耗时
- 开机第 6 秒 S19 执行时收短信进程尚未启动，前后都是 `0` 属正常，日志会明确标注
  「开机早期，交给系统服务拉起」；开机完成后应为 1 个实例
- 日志超过 64KB 自动截断保留后半，单次开机约 6 行，正常可用数年
- 只影响日志，自愈行为本身与 1.0.2 完全一致

### 修正：在线安装的拉包回退

`codeload.github.com` 不通时会回退到 `api.github.com/.../tarball/main`，两者解压出来的顶层
目录名不同（`e5-mms-patch-main` ↔ `qingchangsheng123-e5-mms-patch-<sha>`），旧逻辑只认前者，
于是第二条通道拉到了包却报"下载包结构不对"。现在改为按 `files/sms_pdu.py` 反推安装目录，
两条通道都能装上。

### 修正（并入本版本）

- **开机后出现两个收短信进程**：`S19` 在开机第 6 秒执行时收短信进程尚未启动，
  早期实现判定"没人管"就自己 `setsid` 拉起一个，15 秒后 `e5-sms-notify` 服务又拉一个，
  两个实例同时读 SIM，同一批短信可能被重复处理。现在进程为空一律视为开机早期，
  只还原文件、不碰进程；进程已在跑时才走「终止 → 等回收 → 必要时重拉」。
- **仓库地址**：全部指向当前账号 `qingchangsheng123`，不依赖旧账号名的 301 重定向。

### 功能

- **彩信通知解码**：识别 WAP Push 端口寻址（2948 / 2949），按 WSP Push PDU 解析
  Message-Type / From / Content-Location / Subject / Message-Size（UTF-8、latin1、UTF-16），
  渲染为「【彩信】彩信通知（内容未下载）／内容地址：…」；解析失败退回正文找 http 链接
- **短信转发失败重试**：失败入队，按 30s / 2m / 10m / 30m / 2h / 6h 退避，第 7 次放弃；
  投递记录持久化到 `/etc/unisoc-modem/forward/delivery.log`；支持 `webhook_expect` 校验响应体
- **一键安装 / 完整卸载**：`install.sh` 幂等，支持离线包与在线一条命令；`uninstall.sh` 还原厂商原版
- **开机自愈**：`/etc/init.d/e5-mms`（START=19）每次开机早于短信服务执行一次幂等安装
