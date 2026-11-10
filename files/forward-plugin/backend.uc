// 短信转发插件后端：只是 sms-forward 的一层状态视图。
//
// 所有写操作都落到 /usr/libexec/unisoc-modem/sms-forward 已有的
// set / test-start / queue-retry 上，这里不自己发短信、不改配置文件格式。
//
// 安全：get 的 config 里 webhook_body 带推送 token，不下发给前端，只给 host。

'use strict';

import { writefile } from 'fs';

const FWD = 'e5-forward';
const SET_FILE = '/tmp/e5-forward-set.json';
const DELIVERY_LOG = '/etc/unisoc-modem/forward/delivery.log';

const RESULT_ZH = {
	sent: '成功', disabled: '已停用', self_forward_blocked: '自转发拦截',
	message_too_long: '内容过长', storage_failed: '存储失败',
	source_unavailable: '来源不可用', power_unavailable: '电源不可用',
	invalid_config: '配置错误', invalid_forward_config: '配置无效',
	invalid_destination: '目标无效', delivery_failed: '投递失败',
	smtp_auth_failed: '认证失败', service_rejected: '服务拒绝',
	service_answer_missing: '无应答'
};

// 投递日志里的"原因=xxx"是脚本内部代号，翻译成界面能读的词。
const REASON_ZH = {
	invalid_destination: '目标无效', delivery_failed: '投递失败',
	service_rejected: '服务拒绝', service_answer_missing: '无应答',
	message_too_long: '内容过长', storage_failed: '存储失败',
	source_unavailable: '来源不可用', smtp_auth_failed: '认证失败'
};

return function(ctx) {
	function sh(cmd) {
		let out = ctx.sh(cmd);
		return type(out) == 'string' ? trim(out) : '';
	}

	function parse(text) {
		try { return json(text); } catch (e) { return null; }
	}

	function view() {
		let get = parse(sh(`${FWD} get`));
		if (get == null)
			return { ok: false, error: 'forward unavailable' };
		let c = get.config ?? {}, st = get.status ?? {};
		let q = parse(sh(`${FWD} queue`)) ?? {};
		let target = null;
		let m = match(c.webhook_url ?? '', /^https:\/\/([^\/?#]+)/);
		if (m) target = m[1];
		let recent = [];
		for (let h in (st.history ?? [])) {
			if (length(recent) >= 5) break;
			push(recent, { time: h.time, kind: h.kind, result: h.result,
				label: RESULT_ZH[h.result] ?? h.result });
		}
		// status.history 只保留进程内最近 30 条且重启即空；投递日志在磁盘上，
		// 作为兜底给 UI 一段"最近发生了什么"的文本。
		let log = [];
		if (length(recent) == 0) {
			let raw = sh(`tail -n 5 ${DELIVERY_LOG}`);
			for (let line in split(raw, '\n')) {
				if (line == '') continue;
				let m = match(line, /^\d{4}-\d\d-\d\d (\d\d:\d\d):\d\d (.*)$/);
				if (m == null) continue;
				let text = replace(m[2], /id=\d{10,}[0-9.]*\s*/, '');
				text = replace(text, / \d{10,}[0-9.]*\s*$/, '');
				for (let k in REASON_ZH)
					text = replace(text, '原因=' + k, '原因=' + REASON_ZH[k]);
				push(log, m[1] + ' ' + text);
			}
			// tail 是旧的在前；屏幕上的列表最新的放最上面。
			let newest = [];
			for (let i = length(log) - 1; i >= 0; i--) push(newest, log[i]);
			log = newest;
		}
		return {
			ok: true,
			enabled: c.enabled === true,
			method: c.method ?? 'webhook',
			target,
			last_result: st.last_result ?? 'idle',
			last_label: RESULT_ZH[st.last_result] ?? st.last_result ?? 'idle',
			queue: { pending: q.pending ?? 0, limit: q.limit ?? 7 },
			recent, log
		};
	}

	// set 是全量写：缺省字段会被清空，所以必须把 get 到的配置展平后整体回传。
	// smtp_password / dingtalk_secret 从不下发，也就不回传：缺省时脚本保留原值。
	function write_enabled(on) {
		let get = parse(sh(`${FWD} get`));
		let c = get?.config;
		if (c == null) return { ok: false, error: 'forward unavailable' };
		let smtp = c.smtp ?? {};
		let payload = {
			enabled: on ? 1 : 0,
			method: c.method ?? 'webhook',
			template_language: c.template_language ?? 'zh',
			webhook_url: c.webhook_url ?? '',
			webhook_method: c.webhook_method ?? 'POST',
			webhook_content_type: c.webhook_content_type ?? 'application/json',
			webhook_body: c.webhook_body ?? '',
			webhook_headers: c.webhook_headers ?? '',
			webhook_timeout: c.webhook_timeout ?? 12,
			webhook_expect: c.webhook_expect ?? '__keep__',
			dingtalk_webhook: c.dingtalk_webhook ?? '',
			sms_to_phone: c.sms_to_phone ?? '',
			smtp_host: smtp.host ?? '', smtp_port: smtp.port ?? 465,
			smtp_username: smtp.username ?? '', smtp_to: smtp.to ?? '',
			power_forward_enabled: c.power_forward_enabled ? 1 : 0,
			blacklist_phone: c.blacklist_phone ?? '',
			blacklist_keywords: c.blacklist_keywords ?? '',
			nickname: c.nickname ?? '',
			smtp_forward_device_info: c.smtp_forward_device_info ? 1 : 0,
			dingtalk_forward_device_info: c.dingtalk_forward_device_info ? 1 : 0,
			sms_forward_device_info: c.sms_forward_device_info ? 1 : 0
		};
		writefile(SET_FILE, sprintf('%J', payload));
		let r = parse(sh(`${FWD} set < ${SET_FILE}`));
		sh(`rm -f ${SET_FILE}`);
		if (r?.ok != 1)
			return { ok: false, error: r?.error ?? 'set failed' };
		return view();
	}

	return {
		'GET /status': function(req) { return view(); },
		'POST /toggle': function(req) {
			let on = req.body?.on;
			if (type(on) != 'bool')
				return { status: 400, type: 'application/json', body: '{"error":"on: true or false"}' };
			return write_enabled(on);
		},
		'POST /test': function(req) {
			let r = parse(sh(`${FWD} test-start`));
			if (r?.ok == 1) return { ok: true, started: true };
			return { ok: false, error: r?.error ?? 'test failed' };
		},
		'POST /retry': function(req) {
			// 队列重试按退避逐条真发，可能几十秒；放后台，页面只看 pending 变化。
			sh(`setsid ${FWD} queue-retry >/dev/null 2>&1 < /dev/null &`);
			return { ok: true };
		}
	};
};
