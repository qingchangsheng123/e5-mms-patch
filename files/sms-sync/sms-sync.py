#!/usr/bin/env python3
"""E5 dual-system SMS sync.

OpenWrt keeps its inbox in /etc/e5-sms/inbox.json; Android keeps the same
messages in TelephonyProvider's mmssms.db.  The two systems never run at the
same time -- they share userdata -- so the sync happens on the OpenWrt side:

  pull   Android rows without creator='e5-sync'  -> inbox.json (identity=android)
  push   inbox messages without a sync fingerprint -> mmssms.db (creator='e5-sync')

Rows this tool writes carry creator='e5-sync' and inbox entries carry sync_fp,
which is what stops the two directions from echoing each other.  The database
is only touched when Android is not running; userdata is remounted rw for the
write and put back to ro afterwards, with a copy of the database kept first.

  sms-sync run [--dry-run] [--verbose]
  sms-sync status
"""
import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path

try:
    import fcntl
except ImportError:  # 仅用于 Windows 上的本地演练，设备端一定有
    fcntl = None

INBOX = Path(os.environ.get('E5_SMS_INBOX', '/etc/e5-sms/inbox.json'))
RUN = Path(os.environ.get('E5_SMS_RUN', '/tmp/run/e5-sms'))
DATA = Path(os.environ.get('E5_SMS_SYNC_DATA', '/etc/e5/sms-sync'))
DB = Path(os.environ.get('E5_SMS_ANDROID_DB',
                         '/mnt/e5-data/user_de/0/com.android.providers.telephony/databases/mmssms.db'))
USERDATA = os.environ.get('E5_SMS_USERDATA', '/mnt/e5-data')
LOG = DATA / 'sync.log'
BACKUP = DATA / 'backup'
CREATOR = 'e5-sync'
ANDROID = 'android'
SUB_ID = 1
MAX_LOG = 64 * 1024


def log(message):
    DATA.mkdir(parents=True, exist_ok=True)
    line = '%s %s\n' % (time.strftime('%Y-%m-%d %H:%M:%S'), message)
    try:
        if LOG.exists() and LOG.stat().st_size > MAX_LOG:
            keep = LOG.read_bytes()[-(MAX_LOG // 2):]
            LOG.write_bytes(keep)
        with LOG.open('a', encoding='utf-8') as stream:
            stream.write(line)
    except OSError:
        pass
    sys.stdout.write(line)
    sys.stdout.flush()


def fingerprint(direction, number, epoch, text):
    raw = '%s|%s|%s|%s' % (direction, number or '', int(epoch or 0), text or '')
    return hashlib.sha1(raw.encode('utf-8')).hexdigest()[:20]


def iso_local(epoch):
    moment = time.localtime(int(epoch))
    zone = time.strftime('%z', moment)
    if len(zone) == 5:
        zone = zone[:3] + ':' + zone[3:]
    return time.strftime('%Y-%m-%dT%H:%M:%S', moment) + zone


def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.%d.part' % os.getpid())
    with temporary.open('w', encoding='utf-8') as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, ensure_ascii=False)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)
    try:
        handle = os.open(str(path.parent), os.O_RDONLY)
    except OSError:
        return  # Windows 等不允许对目录 fsync 的文件系统，仅本地演练会走到这里
    try:
        os.fsync(handle)
    finally:
        os.close(handle)


@contextmanager
def inbox_lock():
    RUN.mkdir(parents=True, exist_ok=True)
    with (RUN / 'inbox.lock').open('a') as stream:
        if fcntl is not None:
            fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def load_inbox():
    if not INBOX.exists():
        return None
    with INBOX.open(encoding='utf-8') as stream:
        return json.load(stream)


def android_running():
    for entry in os.listdir('/proc'):
        if not entry.isdigit():
            continue
        try:
            with open('/proc/%s/comm' % entry) as stream:
                if stream.read().strip() in ('system_server', 'zygote', 'zygote64'):
                    return True
        except OSError:
            continue
    return False


def is_read_only(path):
    with open('/proc/mounts') as stream:
        for line in stream:
            fields = line.split()
            if len(fields) >= 4 and fields[1] == path:
                return 'ro' in fields[3].split(',')
    return None


def remount(read_only):
    target = 'remount,ro' if read_only else 'remount,rw'
    subprocess.run(['mount', '-o', target, USERDATA], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)


def backup_database():
    BACKUP.mkdir(parents=True, exist_ok=True)
    target = BACKUP / ('mmssms-%s.db' % time.strftime('%Y%m%d-%H%M%S'))
    shutil.copy2(DB, target)
    kept = sorted(BACKUP.glob('mmssms-*.db'))
    for old in kept[:-3]:
        try:
            old.unlink()
        except OSError:
            pass
    return target


ANDROID_ROWS = ('SELECT _id, address, date, date_sent, type, read, body, subject, creator '
                'FROM sms WHERE creator IS NULL OR creator != ? ORDER BY _id')

PUSHED_ROWS = 'SELECT address, date, type, body FROM sms WHERE creator = ?'


def plan(conn, inbox):
    """Work out both directions without writing anything."""
    pulled, pushed = [], []
    known = {m.get('sync_fp') for m in inbox.get('messages', []) if m.get('sync_fp')}
    for row in conn.execute(ANDROID_ROWS, (CREATOR,)):
        _, address, date, date_sent, kind, read, body, subject, _creator = row
        direction = {1: 'in', 2: 'out', 5: 'out'}.get(kind)
        text = (body or subject or '').strip()
        if not direction or not text:
            continue
        epoch = int((date or date_sent or 0) // 1000)
        mark = fingerprint(direction, address, epoch, text)
        if mark in known:
            continue
        known.add(mark)
        pulled.append({
            'fingerprint': mark,
            'message': {
                'card': 0, 'sim': 'SIM1', 'identity': ANDROID,
                'unread': False, 'historical': True, 'first_seen': epoch,
                'forward_attempted': True, 'direction': direction,
                'number': address or '', 'time': iso_local(epoch), 'epoch': epoch,
                'text': text, 'state': 'received', 'parts': [], 'concat': {},
                'total_parts': 1, 'source': ANDROID, 'sync_fp': mark,
            },
        })

    mirrored = set()
    for address, date, kind, body in conn.execute(PUSHED_ROWS, (CREATOR,)):
        direction = {1: 'in', 2: 'out'}.get(kind)
        if direction:
            mirrored.add(fingerprint(direction, address, int((date or 0) // 1000),
                                     (body or '').strip()))

    for message in inbox.get('messages', []):
        if message.get('deleted'):
            continue
        if message.get('source') == ANDROID:
            continue  # 本来就来自 Android，不需要回写
        if message.get('state') != 'received' and message.get('direction') != 'out':
            continue
        text = (message.get('text') or '').strip()
        if not text:
            continue
        direction = 'out' if message.get('direction') == 'out' else 'in'
        epoch = int(message.get('epoch') or 0)
        if not epoch:
            continue
        mark = message.get('sync_fp') or fingerprint(direction, message.get('number'), epoch, text)
        if mark in mirrored:
            continue
        mirrored.add(mark)
        pushed.append({'fingerprint': mark, 'inbox_id': message.get('id'),
                       'number': message.get('number') or '',
                       'epoch': epoch, 'text': text, 'direction': direction,
                       'read': 0 if message.get('unread') else 1})
    return pulled, pushed


def default_sub_id():
    """Android subscription id: use the real one when telephony.db knows it."""
    telephony = DB.parent / 'telephony.db'
    try:
        conn = sqlite3.connect('file:%s?mode=ro' % telephony, uri=True, timeout=5)
        try:
            row = conn.execute('SELECT _id FROM subscription ORDER BY _id LIMIT 1').fetchone()
            return int(row[0]) if row else 1
        finally:
            conn.close()
    except (sqlite3.Error, OSError):
        return 1


def ensure_thread(conn, address):
    row = conn.execute('SELECT _id FROM canonical_addresses WHERE address = ?', (address,)).fetchone()
    if row:
        canonical = row[0]
    else:
        canonical = conn.execute('INSERT INTO canonical_addresses (address) VALUES (?)',
                                 (address,)).lastrowid
    recipient = str(canonical)
    row = conn.execute('SELECT _id FROM threads WHERE recipient_ids = ?', (recipient,)).fetchone()
    if row:
        return row[0]
    return conn.execute(
        'INSERT INTO threads (date, message_count, recipient_ids, snippet, snippet_cs, '
        'read, archived, type, error, has_attachment) '
        'VALUES (?, 0, ?, ?, 0, 1, 0, 0, 0, 0)',
        (int(time.time() * 1000), recipient, '')).lastrowid


def insert_message(conn, thread_id, item):
    kind = 2 if item['direction'] == 'out' else 1
    cursor = conn.execute(
        'INSERT INTO sms (thread_id, address, person, date, date_sent, protocol, read, '
        'status, type, reply_path_present, subject, body, service_center, locked, '
        'sub_id, error_code, creator, seen) '
        'VALUES (?, ?, NULL, ?, ?, 0, ?, -1, ?, 0, NULL, ?, NULL, 0, ?, -1, ?, 1)',
        (thread_id, item['number'], item['epoch'] * 1000, item['epoch'] * 1000,
         item['read'], kind, item['text'], SUB_ID, CREATOR))
    return cursor.lastrowid


def settle_threads(conn, thread_ids):
    """The insert trigger stamps threads.date with 'now'; restore real times."""
    for thread_id in thread_ids:
        conn.execute(
            'UPDATE threads SET '
            'date = COALESCE((SELECT MAX(date) FROM sms WHERE thread_id = threads._id), date), '
            "snippet = COALESCE((SELECT body FROM sms WHERE thread_id = threads._id "
            "ORDER BY date DESC, _id DESC LIMIT 1), snippet), snippet_cs = 0, "
            'message_count = (SELECT COUNT(*) FROM sms WHERE thread_id = threads._id AND type != 3) '
            '+ (SELECT COUNT(*) FROM pdu WHERE thread_id = threads._id '
            'AND (m_type = 132 OR m_type = 130 OR m_type = 128) AND msg_box != 3), '
            'read = CASE (SELECT COUNT(*) FROM sms WHERE read = 0 AND thread_id = threads._id) '
            'WHEN 0 THEN 1 ELSE 0 END '
            'WHERE _id = ?', (thread_id,))


def write_inbox(pulled):
    """Append pulled messages under the inbox lock, re-checking for duplicates."""
    if not pulled:
        return 0
    added = 0
    with inbox_lock():
        data = load_inbox()
        if data is None:
            return 0
        seen = {m.get('sync_fp') for m in data.get('messages', []) if m.get('sync_fp')}
        for item in pulled:
            if item['fingerprint'] in seen:
                continue
            message = dict(item['message'])
            message['id'] = data['next_id']
            data['next_id'] += 1
            data['messages'].append(message)
            seen.add(item['fingerprint'])
            added += 1
        if added:
            data['updated'] = int(time.time())
            atomic(INBOX, data)
    return added


def mark_synced(pushed):
    """Remember which inbox messages already exist in Android, keyed by id."""
    if not pushed:
        return 0
    marked = 0
    with inbox_lock():
        data = load_inbox()
        if data is None:
            return 0
        by_id = {message.get('id'): message for message in data.get('messages', [])}
        for item in pushed:
            message = by_id.get(item['inbox_id'])
            if message is None or message.get('sync_fp') == item['fingerprint']:
                continue
            message['sync_fp'] = item['fingerprint']
            marked += 1
        if marked:
            atomic(INBOX, data)
    return marked


def store_state(result):
    DATA.mkdir(parents=True, exist_ok=True)
    atomic(DATA / 'state.json', dict(result, updated=int(time.time())))


def run(dry_run=False, verbose=False):
    global SUB_ID
    if not DB.exists():
        log('skip: Android database missing (%s)' % DB)
        return 0
    if android_running():
        log('skip: Android is running')
        return 0
    if is_read_only(USERDATA) is None:
        log('skip: %s is not mounted' % USERDATA)
        return 1
    inbox = load_inbox()
    if inbox is None:
        log('skip: inbox missing (%s)' % INBOX)
        return 1

    conn = sqlite3.connect('file:%s?mode=ro' % DB, uri=True, timeout=15)
    try:
        pulled, pushed = plan(conn, inbox)
    finally:
        conn.close()

    SUB_ID = default_sub_id()
    if pulled or pushed or verbose:
        log('plan: android->openwrt %d, openwrt->android %d (sub_id %d)'
            % (len(pulled), len(pushed), SUB_ID))
    if verbose:
        for item in pulled:
            log('  pull %s %s %ss' % (item['message']['direction'], item['message']['number'],
                                      item['message']['epoch']))
        for item in pushed:
            log('  push %s %s %ss' % (item['direction'], item['number'], item['epoch']))
    if dry_run or not (pulled or pushed):
        if not dry_run:
            print('ok: 两侧已一致，无变化')
        return 0

    read_only = is_read_only(USERDATA)
    inserted = []
    try:
        if read_only:
            remount(False)
        copy = backup_database()
        conn = sqlite3.connect(str(DB), timeout=20)
        conn.execute('PRAGMA busy_timeout = 20000')
        try:
            with conn:
                threads = set()
                for item in pushed:
                    thread_id = ensure_thread(conn, item['number'])
                    threads.add(thread_id)
                    inserted.append(insert_message(conn, thread_id, item))
                if threads:
                    settle_threads(conn, threads)
        finally:
            conn.close()
            os.sync() if hasattr(os, 'sync') else None
    except Exception as error:
        log('error: %s' % error)
        raise
    finally:
        if read_only:
            try:
                remount(True)
            except subprocess.CalledProcessError as error:
                log('warning: remount ro failed: %s' % error)

    added = write_inbox(pulled)
    marked = mark_synced(pushed)
    result = {'database': str(DB), 'backup': copy.name, 'pushed': len(inserted),
              'pulled': added, 'android_total': len(pulled), 'marked': marked}
    store_state(result)
    log('done: pushed %d, pulled %d (backup %s)' % (len(inserted), added, copy.name))
    return 0


def status():
    inbox = load_inbox()
    rows = [('inbox', str(INBOX))]
    if inbox is not None:
        messages = inbox.get('messages', [])
        rows.append(('inbox messages', str(len(messages))))
        rows.append(('from android', str(sum(1 for m in messages if m.get('source') == ANDROID))))
        rows.append(('synced to android', str(sum(1 for m in messages if m.get('sync_fp')))))
    rows.append(('android database', str(DB) + (' ok' if DB.exists() else ' missing')))
    if DB.exists():
        conn = sqlite3.connect('file:%s?mode=ro' % DB, uri=True, timeout=10)
        try:
            rows.append(('android sms rows', str(conn.execute('SELECT COUNT(*) FROM sms').fetchone()[0])))
            rows.append(('written by sync', str(conn.execute(
                'SELECT COUNT(*) FROM sms WHERE creator = ?', (CREATOR,)).fetchone()[0])))
        finally:
            conn.close()
    rows.append(('android running', 'yes' if android_running() else 'no'))
    rows.append(('userdata', 'ro' if is_read_only(USERDATA) else 'rw'))
    state = DATA / 'state.json'
    if state.exists():
        rows.append(('last run', json.loads(state.read_text()).get('updated', 0)))
    for name, value in rows:
        if name == 'last run' and value:
            value = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(int(value)))
        print('%-22s %s' % (name + ':', value))
    return 0


def main():
    parser = argparse.ArgumentParser(description='E5 OpenWrt <-> Android SMS sync')
    sub = parser.add_subparsers(dest='command')
    runner = sub.add_parser('run')
    runner.add_argument('--dry-run', action='store_true')
    runner.add_argument('--verbose', action='store_true')
    sub.add_parser('status')
    args = parser.parse_args()
    if args.command == 'status':
        return status()
    return run(dry_run=getattr(args, 'dry_run', False), verbose=getattr(args, 'verbose', False))


if __name__ == '__main__':
    sys.exit(main())
