#!/usr/bin/env python3
"""Deploy a file to the openclash-rt Debian test box (172.20.0.101).

Usage:
  deploy-file.py put <local> <remote> [--syntax <lua|sh|py|->]
  deploy-file.py run "<shell command>"

Credentials come from env: OCRT_DEBIAN_URL (default 172.20.0.101), OCRT_DEBIAN_PWD.
"""
import argparse
import base64
import os
import sys

import paramiko


def connect():
    host = os.environ.get("OCRT_DEBIAN_URL", "172.20.0.101")
    pwd = os.environ.get("OCRT_DEBIAN_PWD", "password")
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, username="root", password=pwd, allow_agent=False,
              look_for_keys=False, timeout=15, banner_timeout=15,
              auth_timeout=15)
    return c


def run_script(c, script, timeout=180):
    """Run a shell script on the remote host.

    The script is base64-encoded before being handed to exec_command: Git Bash
    rewrites any /-leading token in the local command line into a Windows path,
    and paramiko's exec_command has no env= escape hatch. Encoding keeps the
    local command line pure base64 so nothing can be mangled.
    """
    payload = base64.b64encode(script.encode()).decode()
    si, so, se = c.exec_command(f"echo {payload} | base64 -d | /bin/sh",
                                timeout=timeout)
    out = so.read().decode("utf-8", errors="replace")
    err = se.read().decode("utf-8", errors="replace")
    chan = getattr(si, "channel", si)
    return chan.recv_exit_status(), out, err


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="action", required=True)

    p1 = sub.add_parser("put")
    p1.add_argument("local")
    p1.add_argument("remote",
                    help="remote absolute path WITHOUT leading slash, e.g. "
                         "usr/lib/lua/luci/cbi.lua (a leading / would be "
                         "rewritten into a Windows path by Git Bash)")
    p1.add_argument("--syntax", default="lua")

    p2 = sub.add_parser("run")
    p2.add_argument("cmd")

    args = ap.parse_args()
    if args.action == "put":
        args.remote = "/" + args.remote.lstrip("/")
    c = connect()
    try:
        if args.action == "put":
            sftp = c.open_sftp()
            # sftp 不跟随目标路径里的软链（如 /usr/lib/lua/luci -> 5.1/luci），
            # 所以先传到 /tmp，再在远端 cp 落位。
            sftp.put(os.path.abspath(args.local),
                     "/tmp/.deploy-" + os.path.basename(args.remote))
            sftp.close()
            tmp = "/tmp/.deploy-" + os.path.basename(args.remote)
            check = {
                "lua": f"luac -p {tmp} 2>&1; echo SYNTAX_RC=$?",
                "sh": f"sh -n {tmp} 2>&1; echo SYNTAX_RC=$?",
            }.get(args.syntax, "echo SYNTAX_RC=skipped")
            script = (f"{check} || exit 1\n"
                      f"cp {tmp} {args.remote} && rm -f {tmp}\n"
                      f"rm -f /tmp/luci-indexcache.* /tmp/luci-modulecache/* 2>/dev/null\n"
                      f"md5sum {args.remote}\n"
                      f"wc -l {args.remote}\n")
            rc, out, err = run_script(c, script, timeout=60)
            print(out, end="")
            if err:
                print(err, file=sys.stderr, end="")
            sys.exit(rc)
        else:
            rc, out, err = run_script(c, args.cmd)
            print(f"[rc={rc}]")
            print(out, end="" if out.endswith("\n") else "\n")
            if err:
                print(err, file=sys.stderr, end="")
    finally:
        c.close()


if __name__ == "__main__":
    main()