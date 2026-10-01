#!/usr/bin/env python3
"""SSH helper: connect with password, run command(s), or push key."""
import argparse
import sys
import os
import paramiko

class SSHSession:
    def __init__(self, host, user, password, port=22):
        self.host = host
        self.user = user
        self.password = password
        self.port = port
        self.client = None

    def connect(self):
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        c.connect(
            hostname=self.host, port=self.port, username=self.user,
            password=self.password, allow_agent=False, look_for_keys=False,
            timeout=15, banner_timeout=15, auth_timeout=15,
        )
        self.client = c

    def run(self, cmd, timeout=60):
        """Run a command. Returns (rc, stdout, stderr)."""
        if self.client is None:
            self.connect()
        si, so, se = self.client.exec_command(cmd, timeout=timeout)
        out = so.read().decode("utf-8", errors="replace")
        err = se.read().decode("utf-8", errors="replace")
        # paramiko 5.x: si is ChannelStdinFile; channel is on the attribute.
        chan = getattr(si, "channel", si)
        rc = chan.recv_exit_status()
        return rc, out, err

    def close(self):
        if self.client:
            self.client.close()

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="action", required=True)

    p1 = sub.add_parser("pushkey")
    p1.add_argument("--host", required=True)
    p1.add_argument("--user", default="root")
    p1.add_argument("--password", required=True)
    p1.add_argument("--key", required=True)

    p2 = sub.add_parser("run")
    p2.add_argument("--host", required=True)
    p2.add_argument("--user", default="root")
    p2.add_argument("--password", required=True)
    p2.add_argument("--timeout", type=int, default=60)
    p2.add_argument("--cmd", required=True)

    args = ap.parse_args()

    s = SSHSession(args.host, args.user, args.password)
    try:
        if args.action == "pushkey":
            with open(args.key, "r", encoding="utf-8") as f:
                pubkey = f.read().strip()
            safe_key = pubkey.replace('"', '\\"')
            remote_cmd = (
                'set -e\n'
                'mkdir -p ~/.ssh\n'
                'chmod 700 ~/.ssh\n'
                f'grep -qxF "{safe_key}" ~/.ssh/authorized_keys 2>/dev/null || '
                f'printf "%s\\n" "{safe_key}" >> ~/.ssh/authorized_keys\n'
                'chmod 600 ~/.ssh/authorized_keys\n'
                'echo PUSHKEY_OK\n'
            )
            rc, out, err = s.run(remote_cmd, timeout=20)
            print(f"[rc={rc}]\nstdout:\n{out}\nstderr:\n{err}")
            if rc != 0 or "PUSHKEY_OK" not in out:
                sys.exit(1)
        elif args.action == "run":
            rc, out, err = s.run(args.cmd, timeout=args.timeout)
            print(f"[rc={rc}]")
            if out:
                print(out, end="" if out.endswith("\n") else "\n")
            if err:
                print(err, end="" if err.endswith("\n") else "\n", file=sys.stderr)
            sys.exit(rc)
    finally:
        s.close()

if __name__ == "__main__":
    sys.exit(main())