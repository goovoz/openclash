#!/usr/bin/env python3
"""把 mihomo-client 项目同步到真机并构建。

首次会rsync 整个 crate（不含 target/），之后增量。

用法：
    python scripts/_deploy/build-rust.py [--remote-dir DIR] [--release|--debug]
"""
import argparse
import base64
import os
import posixpath
import sys

import paramiko

LOCAL_ROOT = os.path.abspath(os.path.join(
    os.path.dirname(__file__), "..", "..", "mihomo-client"))

# 这些文件/目录参与构建
INCLUDE = ["Cargo.toml", "Cargo.lock", "src"]
EXCLUDE_NAMES = {"target", ".git", "node_modules"}


def collect():
    """返回 (相对路径, 本地绝对路径) 列表。"""
    out = []
    for name in INCLUDE:
        p = os.path.join(LOCAL_ROOT, name)
        if os.path.isfile(p):
            out.append((name, p))
        elif os.path.isdir(p):
            for root, dirs, files in os.walk(p):
                dirs[:] = [d for d in dirs if d not in EXCLUDE_NAMES]
                for f in files:
                    if f in EXCLUDE_NAMES:
                        continue
                    ap = os.path.join(root, f)
                    rel = os.path.relpath(ap, LOCAL_ROOT).replace("\\", "/")
                    out.append((rel, ap))
    return out


def run(ssh, cmd, timeout=600, label=""):
    payload = base64.b64encode(cmd.encode()).decode()
    si, so, se = ssh.exec_command(
        f"echo {payload} | base64 -d | /bin/bash", timeout=timeout)
    import time
    ch = getattr(si, "channel", si)
    t0 = time.time()
    while not ch.exit_status_ready() and time.time() - t0 < timeout - 10:
        time.sleep(2)
    out = so.read().decode("utf-8", "replace")
    err = se.read().decode("utf-8", "replace")
    if label:
        print(f"--- {label} ---")
    print(out)
    if err.strip():
        print("[stderr]", err[-800:])
    return ch.recv_exit_status() if ch.exit_status_ready() else -1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=os.environ.get(
        "OCRT_DEBIAN_URL_SSH", "172.20.0.101"))
    ap.add_argument("--pwd", default=os.environ.get(
        "OCRT_DEBIAN_PWD", "password"))
    ap.add_argument("--remote-dir", default="/opt/ocrt-dev/mihomo-client")
    ap.add_argument("--release", action="store_true", default=True)
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    files = collect()
    if not files:
        print("本地没有找到待同步的文件", file=sys.stderr)
        return 1
    print(f"同步 {len(files)} 个文件 -> {args.remote_dir}")

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(args.host, username="root", password=args.pwd,
                allow_agent=False, look_for_keys=False, timeout=15)

    run(ssh, f"mkdir -p {args.remote_dir}/src", timeout=60)

    sftp = ssh.open_sftp()
    made_dirs = set()
    for rel, ap in files:
        remote = posixpath.join(args.remote_dir, rel)
        d = posixpath.dirname(remote)
        if d not in made_dirs:
            try:
                sftp.mkdir(d)
            except IOError:
                pass
            made_dirs.add(d)
        sftp.put(ap, remote)
    sftp.close()
    print("同步完成")

    prof = "release" if not args.debug else "debug"
    env = (
        "export RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo "
        "PATH=/opt/cargo/bin:$PATH\n"
    )
    rc = run(ssh,
             env + f"cd {args.remote_dir} && cargo build --{prof} 2>&1",
             timeout=900, label="cargo build")
    if rc != 0:
        print("构建失败")
        return rc
    binpath = f"{args.remote_dir}/target/{prof}/mihomo-client"
    run(ssh, f"ls -lh {binpath} && file {binpath}", timeout=60,
        label="产物")
    print(f"\n构建成功: {binpath}")
    return 0


if __name__ == "__main__":
    sys.exit(main())