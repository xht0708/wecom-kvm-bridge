#!/usr/bin/env python3
"""GNOME notification forwarder for timestamp and typed call events from Windows/VirtioFS.

No listening network ports; does not read chat metadata or messages.
"""
import os
import pathlib
import subprocess
import sys
import time

EVENT_FILE = pathlib.Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else pathlib.Path.home() / 'VMShare' / 'WeComBridge' / 'events.log'


def event_kind(line: bytes) -> str:
    # Legacy events are timestamp-only. New call events append a tab-delimited type.
    fields = line.decode('utf-8-sig', errors='replace').strip().split('\t')
    return 'incoming_call' if len(fields) == 2 and fields[1] == 'incoming_call' else 'message'


def notify(kind: str = 'message') -> bool:
    env = dict(os.environ)
    env.setdefault('DBUS_SESSION_BUS_ADDRESS', f'unix:path=/run/user/{os.getuid()}/bus')
    args = ['notify-send', '-a', '企业微信']
    if kind == 'incoming_call':
        args += ['-u', 'critical', '-i', 'call-start', '企业微信', '收到语音或视频通话邀请']
    else:
        args += ['-i', 'dialog-information', '企业微信', '有新消息']
    result = subprocess.run(
        args,
        env=env, check=False, capture_output=True, text=True,
    )
    if result.returncode != 0:
        print('notify-send failed:', result.stderr.strip(), flush=True)
        return False
    return True


def main() -> None:
    print('Listening for WeCom events:', EVENT_FILE, flush=True)
    offset = 0
    identity = None
    initial = True
    partial = b""
    while True:
        try:
            stat = EVENT_FILE.stat()
            new_identity = (stat.st_dev, stat.st_ino)
            if initial:
                # Ignore all stale alerts already written before this daemon starts.
                offset = stat.st_size
                partial = b""
                initial = False
                identity = new_identity
            elif identity != new_identity:
                identity = new_identity
                offset = stat.st_size
                partial = b""
            elif stat.st_size < offset:
                # File truncated/rewritten: do not replay historical notifications.
                offset = stat.st_size
                partial = b""
            elif stat.st_size > offset:
                with EVENT_FILE.open('rb') as f:
                    f.seek(offset)
                    content = f.read()
                    offset = f.tell()
                # Process complete lines individually. Several events may arrive
                # between polls; do not collapse them into one notification.
                partial += content
                *lines, partial = partial.split(b'\n')
                for line in lines:
                    if line.strip():
                        kind = event_kind(line)
                        success = notify(kind)
                        status = 'notification_delivered' if success else 'notification_failed'
                        print(f'{status} type={kind}', flush=True)
        except FileNotFoundError:
            identity = None
            initial = True
            partial = b""
        except Exception as exc:
            print(f'host-listener error: {exc!r}', flush=True)
        time.sleep(0.6)


if __name__ == '__main__':
    main()
