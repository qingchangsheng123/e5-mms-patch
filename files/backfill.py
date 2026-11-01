#!/usr/bin/env python3
"""把收件箱里已经存成乱码的彩信通知，按原始 PDU 重新解码并改写正文。

只动正文（text）：指纹、分片、时间、已读状态、转发记录都不变，所以不会
重复推送、也不会让 SIM 上的短信失去对应关系。

用法：
    python3 /etc/e5/mms/backfill.py          改写
    python3 /etc/e5/mms/backfill.py --dry    只报告，不写
"""
import fcntl
import json
import os
import sys

sys.path.insert(0, '/etc/e5/mms')

INBOX = '/etc/e5-sms/inbox.json'
LOCK = '/tmp/run/e5-sms/inbox.lock'


def decode_parts(message, decoder):
    """Any part of this message that is an MMS notification decides the text."""
    for part in message.get('parts', []):
        pdu = part.get('pdu')
        if not pdu:
            continue
        try:
            decoded = decoder(pdu)
        except (ValueError, IndexError):
            continue
        if decoded and decoded.get('mms'):
            return decoded['text']
    return None


def save(path, data):
    temporary = path + '.backfill.part'
    with open(temporary, 'w') as file:
        os.chmod(temporary, 0o600)
        json.dump(data, file, ensure_ascii=False)
        file.write('\n')
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)
    directory = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def main():
    dry = '--dry' in sys.argv
    from sms_pdu import decode

    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    with open(LOCK, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with open(INBOX) as file:
            data = json.load(file)
        changed, mms, scanned = [], 0, 0
        for message in data.get('messages', []):
            scanned += 1
            text = decode_parts(message, decode)
            if text is None:
                continue
            mms += 1
            if text != message.get('text'):
                changed.append({'id': message['id'], 'from': message.get('number'),
                                'old': (message.get('text') or '')[:40], 'new': text})
                message['text'] = text
        if changed and not dry:
            save(INBOX, data)

    print(json.dumps({'scanned': scanned, 'mms': mms, 'rewritten': len(changed),
                      'dry': dry, 'items': changed}, ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()
