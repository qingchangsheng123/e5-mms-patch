# 更新记录

## 1.0.0 — 2026-11-01

首个版本，从一台实机（E5 / UMS9621 / `6.18.54-e5-sleep14`）的部署中整理而来。

### 彩信

- 新增 WAP Push 端口寻址识别（destination port 2948 / 2949，MMS notification）
- 新增 WSP Push PDU 解析：Message-Type、From、Content-Location、Subject、Message-Size，
  覆盖 UTF-8 / latin1 / UTF-16 三种编码串
- 通知文案改为「【彩信】彩信通知（内容未下载）／内容地址：…」
- 字段解析不出来时退回「正文里搜 http 链接」的容错路径，避免整条通知丢空
- 历史消息回填工具 `backfill.py`：只改正文，不动指纹、分片、时间、已读状态

### 短信转发

- 投递失败不再一次性丢弃：入队后按 **30s / 2m / 10m / 30m / 2h / 6h** 退避重试，第 7 次放弃
- 只对可重试结果入队（网络不通、DNS 失败、服务端拒绝、源不可用等）
- 投递记录持久化到 `/etc/unisoc-modem/forward/delivery.log`，超 200KB 自动截断
- 新增 `e5-forward status` / `queue` / `queue-retry` 子命令
- 支持用 `webhook_expect` 校验响应体，避免 token 失效时被 `HTTP 200` 骗过

### 部署

- `install.sh` 一键安装 / 升级，幂等；支持离线包内执行和在线一条命令
- `uninstall.sh` 完整回滚到厂商原版
- `/etc/init.d/e5-mms`（START=19）开机自愈，系统升级覆盖 `/usr` 后自动补装
