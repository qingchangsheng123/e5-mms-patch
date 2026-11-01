"""SMS-DELIVER decoding (3GPP TS 23.038/23.040), without third-party modules."""
from datetime import datetime, timedelta, timezone
import hashlib
import math
import re

GSM7 = ('@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\x1bÆæßÉ'
        ' !"#¤%&\'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§'
        '¿abcdefghijklmnopqrstuvwxyzäöñüà')
EXT = {10: '\f', 20: '^', 40: '{', 41: '}', 47: '\\', 60: '[', 61: '~', 62: ']', 64: '|', 101: '€'}


# ---- MMS: WAP Push notification (port 2948/2949) -------------------------
MMS_PUSH_PORTS = (2948, 2949)

def _text_string(data, i):
    """WSP Text-string: NUL-terminated printable run."""
    end = data.find(b'\x00', i)
    if end < 0:
        end = len(data)
    return data[i:end].decode('utf-8', 'replace'), end + 1

def _encoded_string(data, i, length=None):
    """WSP Encoded-string-value: charset token, then the text."""
    end = i + length if length is not None else len(data)
    if i >= len(data):
        return ''
    charset = data[i]
    body = data[i + 1:end]
    codes = {0x83: 'utf-8', 0x84: 'utf-8', 0x85: 'utf-8', 0x86: 'utf-8',
             0x88: 'utf-8', 0x89: 'utf-8', 0x81: 'latin1', 0x82: 'latin1'}
    if charset in codes:
        return body.rstrip(b'\x00').decode(codes[charset], 'replace')
    if body[:1] == b'\xff' or body[:2] in (b'\xfe\xff',):
        return body.decode('utf-16-be' if body[:2] != b'\xff\xfe' else 'utf-16-le', 'replace')
    return body.rstrip(b'\x00').decode('utf-8', 'replace')

def _long_integer(data, i):
    if i >= len(data):
        return None, i
    lead = data[i]
    if lead & 0x80:
        size = lead & 0x7f
        return int.from_bytes(data[i + 1:i + 1 + size], 'big'), i + 1 + size
    return None, i + 1

def mms_notification(push):
    """Read a WSP Push PDU carrying an MMS notification; None if it is not one."""
    if len(push) < 4 or push[1] != 0x06:
        return None
    header_length = push[2]
    headers, body = push[3:3 + header_length], push[3 + header_length:]
    if 0xaf not in headers and b'mms' not in headers.lower():
        return None
    found = {}
    at = 0
    while at < len(body):
        field = body[at]
        at += 1
        if field == 0x8e:                      # X-Mms-Message-Size
            value, at = _long_integer(body, at)
            if value: found['size'] = value
        elif field in (0x96, 0x83, 0x88):      # Subject, Content-Location, Expiry
            if at >= len(body):
                break
            length, at = body[at], at + 1
            if at + length > len(body):
                break
            chunk, at = body[at:at + length], at + length
            if field == 0x96:
                subject = _encoded_string(chunk, 0, len(chunk)).strip()
                if subject: found['subject'] = subject
            elif field == 0x83:
                url = chunk.split(b'\x00')[0].decode('utf-8', 'replace').strip()
                if url: found['url'] = url
        elif field in (0x8c, 0x8d, 0x8a):      # Message-Type, Version, Class
            at += 1
        elif field == 0x98:                    # Transaction-ID
            _, at = _text_string(body, at)
        elif field == 0x89:                    # From: a bare address
            if at < len(body) and body[at] == 0x80:
                at += 1
            _, at = _text_string(body, at)
        elif field == 0x8b:                    # Message-ID
            _, at = _text_string(body, at)
        else:
            break
    if 'url' not in found:                     # tolerant fallback
        start = body.find(b'http')
        if start >= 0:
            url, _ = _text_string(body, start)
            if url.startswith('http'): found['url'] = url
    return found or None

def _size_text(size):
    if not size: return ''
    if size >= 1048576: return '%.1f MB' % (size / 1048576.0)
    return '%d KB' % max(1, round(size / 1024.0))

def mms_text(found):
    """The one line the inbox, the info screen and the forwarder get."""
    parts = []
    subject = (found.get('subject') or '').strip()
    if subject: parts.append('主题：' + subject)
    size = _size_text(found.get('size'))
    if size: parts.append(size)
    head = '【彩信】' + (' · '.join(parts) if parts else '彩信通知（内容未下载）')
    url = found.get('url')
    return head + ('\n内容地址：' + url if url else '')


def septets(data, count, offset=0):
    if offset + count * 7 > len(data) * 8:
        raise ValueError('truncated GSM7 user data')
    value = int.from_bytes(data, 'little')
    result, escape = [], False
    for i in range(count):
        code = (value >> (offset + i * 7)) & 127
        if escape:
            result.append(EXT.get(code, '\ufffd')); escape = False
        elif code == 27:
            escape = True
        else:
            result.append(GSM7[code])
    if escape:
        result.append('\ufffd')
    return ''.join(result)


def decode(pdu):
    data = bytes.fromhex(pdu)
    if not data:
        raise ValueError('empty SMS PDU')
    pos = 1 + data[0]
    if pos > len(data):
        raise ValueError('truncated SMSC address')
    smsc = data[:pos].hex()

    def take(size):
        nonlocal pos
        if pos + size > len(data):
            raise ValueError('truncated SMS PDU')
        result = data[pos:pos + size]; pos += size
        return result

    flags = take(1)[0]
    if flags & 3 != 0:
        return None  # submit/status-report are handled by ModemManager
    size, toa = take(2)
    address = take((size + 1) // 2)
    if toa & 0x70 == 0x50:
        number = septets(address, size * 4 // 7)
    else:
        digits = ''.join(f'{byte & 15:X}{byte >> 4:X}' for byte in address)[:size]
        number = ('+' if toa & 0x70 == 0x10 else '') + digits
    pid, dcs = take(2)
    scts = take(7)
    semi = lambda b: (b & 15) * 10 + (b >> 4)
    values = [semi(b) for b in scts[:6]]
    tz = semi(scts[6] & 0xf7) * 15 * (-1 if scts[6] & 8 else 1)
    dt = datetime(2000 + values[0], *values[1:], tzinfo=timezone(timedelta(minutes=tz)))
    udl = take(1)[0]
    if dcs & 0xc0 == 0:
        if dcs & 0x20:
            raise ValueError('compressed SMS is unsupported')
        alphabet = (dcs >> 2) & 3
    elif dcs & 0xf0 in (0xc0, 0xd0, 0xe0):
        alphabet = 2 if dcs & 0xf0 == 0xe0 else 0
    elif dcs & 0xf0 == 0xf0:
        alphabet = 1 if dcs & 4 else 0
    else:
        raise ValueError('unsupported SMS alphabet')
    user = take(math.ceil(udl * 7 / 8) if alphabet == 0 else udl)
    header_bytes, concat, extra_header, ports = 0, None, [], None
    if flags & 0x40:
        if not user:
            raise ValueError('missing SMS header')
        header_bytes = user[0] + 1
        if header_bytes > len(user):
            raise ValueError('truncated SMS header')
        at = 1
        while at < header_bytes:
            if at + 2 > header_bytes:
                raise ValueError('invalid SMS header element')
            tag, length = user[at:at + 2]; at += 2
            item = user[at:at + length]; at += length
            if at > header_bytes:
                raise ValueError('invalid SMS header length')
            if tag in (0, 8):
                if concat or length != (3 if tag == 0 else 4):
                    raise ValueError('invalid concatenated SMS header')
                concat = {'ref': item[0] if tag == 0 else int.from_bytes(item[:2], 'big'),
                          'width': 8 if tag == 0 else 16, 'total': item[-2], 'part': item[-1]}
            else:
                extra_header.append((tag, item.hex()))
                if tag == 0x05 and length == 4:
                    ports = (int.from_bytes(item[:2], 'big'), int.from_bytes(item[2:], 'big'))
                if tag in (0x24, 0x25) and any(item):
                    raise ValueError('SMS national language shift table unsupported')
        if concat and not 1 <= concat['part'] <= concat['total'] <= 255:
            raise ValueError('invalid concatenated SMS numbering')
    if alphabet == 0:
        header_septets = math.ceil(header_bytes * 8 / 7)
        text = septets(user, udl - header_septets, header_septets * 7)
    elif alphabet == 2:
        text = user[header_bytes:].decode('utf-16-be', errors='replace')
    elif alphabet == 1:
        text = user[header_bytes:].decode('latin1')
    else:
        raise ValueError('reserved SMS alphabet')
    mms = None
    if ports and any(port in MMS_PUSH_PORTS for port in ports):
        found = mms_notification(user[header_bytes:])
        if found:
            mms, text = found, mms_text(found)
    return {'number': number, 'text': text, 'mms': mms, 'time': dt.isoformat(timespec='seconds'),
            'epoch': int(dt.timestamp()), 'concat': concat, 'dcs': dcs, 'pid': pid,
            'smsc': smsc, 'udh': sorted(extra_header),
            'fingerprint': hashlib.sha256(data).hexdigest(), 'pdu': data.hex()}


def listing(response):
    parts, errors, header = [], [], None
    for line in response.splitlines():
        line = line.strip()
        match = re.match(r'\+CMGL:\s*(\d+)\s*,\s*(\d+)\s*,', line)
        if match:
            header = {'storage_index': int(match[1]), 'storage_status': int(match[2])}
        elif header and re.fullmatch(r'[a-fA-F0-9]+', line):
            try:
                sms = decode(line)
                if sms:
                    parts.append({**sms, **header})
            except (ValueError, IndexError) as error:
                errors.append({'storage_index': header['storage_index'], 'error': str(error)})
            header = None
    if header:
        errors.append({'storage_index': header['storage_index'], 'error': 'missing SMS PDU'})
    return parts, errors


def assemble(parts):
    groups = []
    ambiguous = set()
    def key(part):
        c = part['concat']
        return (part['number'], part['dcs'], part.get('pid'), part.get('smsc'),
                repr(part.get('udh', [])), c.get('width'), c['ref'], c['total'])
    for part in sorted(parts, key=lambda p: (p['epoch'], p['storage_index'])):
        c = part['concat']
        group = None
        if c:
            candidates = []
            for old in groups:
                ref = old[0]['concat']
                if ref and key(old[0]) == key(part) and all(abs(p['epoch'] - part['epoch']) <= 600 for p in old):
                    duplicate = next((p for p in old if p['fingerprint'] == part['fingerprint']), None)
                    if duplicate:
                        duplicate.update(part)
                        group = old
                        break
                    if all(p['concat']['part'] != c['part'] for p in old):
                        candidates.append(old)
            if group is not None:
                continue
            if len(candidates) == 1 and id(candidates[0]) not in ambiguous:
                group = candidates[0]
            elif candidates:
                # A reused reference with two possible messages is not enough
                # information to choose a tail. Keep all fragments unpublished.
                ambiguous.update(id(old) for old in candidates)
                group = []; groups.append(group); ambiguous.add(id(group))
        else:
            duplicate = next((p for old in groups for p in old if p['fingerprint'] == part['fingerprint']), None)
            if duplicate:
                duplicate.update(part)
                continue
        if group is None:
            group = []; groups.append(group)
        group.append(part)
    result = []
    for group in groups:
        c = group[0]['concat']; ordered = sorted(group, key=lambda p: p['concat']['part'] if c else 1)
        complete = id(group) not in ambiguous and (not c or len(ordered) == c['total'])
        first = min(group, key=lambda p: p['epoch'])
        result.append({'number': first['number'], 'time': first['time'], 'epoch': first['epoch'],
                       'text': ''.join(p['text'] for p in ordered), 'state': 'received' if complete else 'receiving',
                       'parts': [{'index': p['storage_index'], 'fingerprint': p['fingerprint'], 'pdu': p.get('pdu')} for p in ordered],
                       'concat': c, 'total_parts': c['total'] if c else 1})
    return result


def submit(number, text, reference=None):
    """SMS-SUBMIT PDUs, GSM7 including extensions or UTF-16 with 16-bit UDH."""
    import secrets
    number = re.sub(r'[ -]', '', number)
    if not re.fullmatch(r'\+?[0-9]{3,20}', number):
        raise ValueError('Invalid recipient number')
    if not text or len(text.encode('utf-8')) > 4000:
        raise ValueError('Message is empty or exceeds 4000 UTF-8 bytes')
    digits = number.lstrip('+')
    semi = digits + ('F' if len(digits) % 2 else '')
    address = bytes(int(semi[i + 1] + semi[i], 16) for i in range(0, len(semi), 2))
    gsm = {char: [i] for i, char in enumerate(GSM7) if i != 27}
    gsm.update({char: [27, i] for i, char in EXT.items()})
    is_gsm = all(char in gsm for char in text)
    encoded = [gsm[char] if is_gsm else char.encode('utf-16-be') for char in text]
    length = sum(len(item) for item in encoded)
    # A 16-bit concatenation header is 7 bytes (8 GSM septets).
    single, multiple = (160, 152) if is_gsm else (140, 132)
    limit = single if length <= single else multiple
    chunks, chunk, used = [], [], 0
    for item in encoded:
        if used + len(item) > limit:
            chunks.append(chunk); chunk, used = [], 0
        chunk.append(item); used += len(item)
    chunks.append(chunk)
    if len(chunks) > 255:
        raise ValueError('Too many SMS parts')
    reference = secrets.randbelow(65536) if reference is None else reference
    result = []
    for index, chunk in enumerate(chunks, 1):
        header = bytes([6, 8, 4, reference >> 8, reference & 255, len(chunks), index]) if len(chunks) > 1 else b''
        if is_gsm:
            codes = [code for item in chunk for code in item]
            offset = math.ceil(len(header) * 8 / 7) * 7
            bits = int.from_bytes(header, 'little')
            for at, code in enumerate(codes):
                bits |= code << (offset + at * 7)
            udl = offset // 7 + len(codes)
            user = bits.to_bytes(math.ceil(udl * 7 / 8), 'little')
        else:
            user = header + b''.join(chunk); udl = len(user)
        pdu = (bytes([0, 0x41 if header else 1, 0, len(digits), 0x91 if number.startswith('+') else 0x81])
               + address + bytes([0, 0 if is_gsm else 8, udl]) + user)
        result.append(pdu.hex().upper())
    return result
