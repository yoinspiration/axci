#!/usr/bin/env python3
#
# Runs NimbOS QEMU command in a PTY and sends "usertests" automatically
# once shell prompt appears, so CI/local runs do not block on interactive input.

import os
import select
import subprocess
import sys

SEND_AFTER = (b"Rust user shell", b">>")
SEND_LINE = b"usertests\n"
SUCCESS_MARKERS = (b"usertests passed!",)


def main() -> int:
    try:
        sep = sys.argv.index("--")
    except ValueError:
        print("Usage: ci_run_qemu_nimbos.py -- <command> [args...]", file=sys.stderr)
        return 2

    cmd = sys.argv[sep + 1 :]
    if not cmd:
        print("No command after --", file=sys.stderr)
        return 2

    import pty

    master, slave = pty.openpty()
    try:
        proc = subprocess.Popen(
            cmd,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
        )
    finally:
        os.close(slave)

    sent = False
    saw_success = False
    buf = b""
    try:
        while True:
            readable, _, _ = select.select([master], [], [], 0.1)
            if readable:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                buf = (buf + chunk)[-1024:]

                if not saw_success and any(marker in buf for marker in SUCCESS_MARKERS):
                    saw_success = True

                if not sent and any(trigger in buf for trigger in SEND_AFTER):
                    try:
                        os.write(master, SEND_LINE)
                        sent = True
                    except OSError:
                        pass

            if proc.poll() is not None:
                while True:
                    readable, _, _ = select.select([master], [], [], 0.05)
                    if not readable:
                        break
                    try:
                        chunk = os.read(master, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                break
    finally:
        os.close(master)

    if saw_success:
        return 0
    return proc.returncode if proc.returncode is not None else 1


if __name__ == "__main__":
    raise SystemExit(main())
