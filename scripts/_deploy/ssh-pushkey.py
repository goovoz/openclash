#!/usr/bin/env python3
"""Push local ssh public key to a remote host via password using pexpect."""
import argparse
import sys
import pexpect

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--user", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--key", required=True, help="local public key file")
    ap.add_argument("--port", type=int, default=22)
    args = ap.parse_args()

    with open(args.key, "r", encoding="utf-8") as f:
        pubkey = f.read().strip()

    # Single command: mkdir + append + chmod.
    # Use double-quotes around key to preserve spaces; escape any internal quotes.
    safe_key = pubkey.replace('"', '\\"')
    remote_cmd = (
        'mkdir -p ~/.ssh && chmod 700 ~/.ssh && '
        f'grep -qxF "{safe_key}" ~/.ssh/authorized_keys 2>/dev/null || '
        f'echo "{safe_key}" >> ~/.ssh/authorized_keys; '
        'chmod 600 ~/.ssh/authorized_keys; '
        'echo OK_INSTALLED_KEY'
    )

    cmd = (
        f"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
        f"-p {args.port} {args.user}@{args.host} {remote_cmd!r}"
    )
    # ssh will parse its own argv, but we want the shell to keep it as one arg.
    # Use a list form instead:
    ssh_argv = [
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-p", str(args.port),
        f"{args.user}@{args.host}",
        remote_cmd,
    ]

    child = pexpect.spawn(ssh_argv[0], ssh_argv[1:], timeout=20, encoding="utf-8")
    sent = False
    while True:
        idx = child.expect([
            r"password:",
            r"Password:",
            r"OK_INSTALLED_KEY",
            pexpect.EOF,
            pexpect.TIMEOUT,
        ])
        if idx in (0, 1):
            child.sendline(args.password)
            sent = True
        elif idx == 2:
            print("OK_INSTALLED_KEY received")
            return 0
        elif idx == 3:
            break
        else:
            print("TIMEOUT", file=sys.stderr)
            return 2
    out = child.before or ""
    sys.stderr.write(out)
    sys.stderr.write("\n")
    if not sent:
        sys.stderr.write("password prompt never appeared\n")
    return 1

if __name__ == "__main__":
    sys.exit(main())