# e5-mms-patch

E5（Unisoc UMS9621）OpenWrt 固件的短信 / 彩信增强补丁，解决两个具体问题：

1. **彩信通知显示成乱码** —— 运营商发来的彩信到达通知（WAP Push）被当成普通短信解码，收件箱里是一串 `?<?` 之类的乱码。
2. **短信转发失败即永久丢失** —— 内置转发脚本投递失败后不会重试，且消息 ID 已被占用，后续再也补发不了。

补丁只改两个用户空间文件，不碰内核、不动固件分区，卸载可完整回滚。

## 环境要求

- E5 类设备（Unisoc UMS9621 基带）+ 基于 `e5-sleep` 系列的 OpenWrt 固件
- 需要存在 `/usr/lib/e5/sms_pdu.py`（短信 PDU 解码器）
- 需要 `python3`（固件自带）
- 固件版本参考：`6.18.54-e5-sleep14`，理论兼容其它 e5-sleep 版本

## 安装

### 方式一：在线一条命令（推荐）

设备能连外网时，直接执行：

```sh
wget -q -O /tmp/e5-mms.sh --header='Accept: application/vnd.github.raw' \
  https://api.github.com/repos/lixin2295368525-cmd/e5-mms-patch/contents/install.sh && sh /tmp/e5-mms.sh
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

然后核心安装逻辑会：

- 备份原版 `/usr/lib/e5/sms_pdu.py` 到 `/etc/e5/mms/sms_pdu.orig.py`，再用带 MMS 解码的版本覆盖；
- 备份原版 `sms-forward` 到 `/etc/e5/mms/sms-forward.orig`，再给它打上失败重试补丁；
- 重启收短信的进程（解码器只在启动时读入文件）；
- 重启转发服务。

**为什么需要开机自愈**：系统升级会重新覆盖 `/usr` 下的文件，而 `/etc/e5` 会保留。`/etc/init.d/e5-mms`（START=19）每次开机早于短信服务执行一次安装，升级后自动补回来，不用手动重装。

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

## 许可

MIT
