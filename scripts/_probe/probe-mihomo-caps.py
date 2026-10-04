#!/usr/bin/env python3
"""用 mihomo 自己的 `-t`（test config）探测它到底支持什么。

比读二进制可靠：Go 编译后的字符串表often 不可 grep，但**配置校验器
是权威的** —— 它接受就是支持，��「unsupported proxy type」就是不支持。

用法：
    python probe-mihomo-caps.py <mihomo-binary>
输出：
    每行 "配置项 -> 支持/不支持（错误信息）"
"""
import subprocess
import sys
import tempfile
import os

BIN = sys.argv[1] if len(sys.argv) > 1 else "/etc/openclash/core/clash_meta"

BASE = """mixed-port: 17890
mode: rule
log-level: silent
external-controller: 127.0.0.1:19090
proxies:
{proxies}
proxy-groups:
  - name: TEST
    type: select
    proxies: [{names}]
    # 兜底：即使上面的名字有问题，也要能看出是协议问题还是引用问题
rules:
  - MATCH,DIRECT
"""

PROXIES = {
    "shadowsocks": """  - name: ss
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-256-gcm
    password: pw
    udp: true""",
    "shadowsocks-r": """  - name: ssr
    type: ssr
    server: 1.2.3.4
    port: 8388
    cipher: aes-256-cfb
    password: pw
    obfs: plain
    protocol: origin
    udp: true""",
    "shadowsocks-2022": """  - name: ss2022
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: 2022-blake3-aes-256-gcm
    password: AAAAAAAAAAAAAAAAAAAAAA==""",
    "vmess": """  - name: vmess
    type: vmess
    server: 1.2.3.4
    port: 443
    uuid: 00000000-0000-0000-0000-000000000000
    alterId: 0
    cipher: auto
    tls: true""",
    "vmess-ws": """  - name: vmessws
    type: vmess
    server: 1.2.3.4
    port: 443
    uuid: 00000000-0000-0000-0000-000000000000
    alterId: 0
    cipher: auto
    tls: true
    network: ws
    ws-opts:
      path: /ws
      headers:
        Host: a.com""",
    "vless-reality": """  - name: vlessr
    type: vless
    server: 1.2.3.4
    port: 443
    uuid: 00000000-0000-0000-0000-000000000000
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: a.com
    reality-opts:
      public-key: k
      short-id: ab""",
    "trojan": """  - name: trojan
    type: trojan
    server: 1.2.3.4
    port: 443
    password: pw
    sni: a.com
    udp: true""",
    "snell": """  - name: snell
    type: snell
    server: 1.2.3.4
    port: 44046
    psk: pw
    version: 4""",
    "hysteria2": """  - name: hy2
    type: hysteria2
    server: 1.2.3.4
    port: 443
    password: pw
    sni: a.com
    skip-cert-verify: false
    up: "30 Mbps"
    down: "200 Mbps\"""",
    "tuic": """  - name: tuic
    type: tuic
    server: 1.2.3.4
    port: 443
    uuid: 00000000-0000-0000-0000-000000000000
    password: pw
    sni: a.com
    alpn: [h3]
    skip-cert-verify: false""",
    "wireguard": """  - name: wg
    type: wireguard
    server: 1.2.3.4
    port: 51820
    ip: 10.0.0.2/32
    ipv6: 'fd00::2/128'
    private-key: aaaa
    public-key: bbbb
    pre-shared-key: cccc
    udp: true""",
    "anytls": """  - name: anytls
    type: anytls
    server: 1.2.3.4
    port: 443
    password: pw
    udp: true
    sni: a.com""",
    "ssh": """  - name: ssh
    type: ssh
    server: 1.2.3.4
    port: 22
    username: u
    password: pw
    private-key: k""",
    "http": """  - name: http
    type: http
    server: 1.2.3.4
    port: 8080
    username: u
    password: pw
    tls: false""",
    "socks5": """  - name: s5
    type: socks5
    server: 1.2.3.4
    port: 1080
    username: u
    password: pw""",
    "mieru": """  - name: mieru
    type: mieru
    server: 1.2.3.4
    port: 443
    password: pw
    plugin: obfs-local
    plugin-opts:
      host: a.com""",
    "naive": """  - name: naive
    type: naive
    server: 1.2.3.4
    port: 443
    username: u
    password: pw""",
}

TOPLEVEL = {
    "tun-stack-mixed": "tun:\n  enable: false\n  stack: mixed\n",
    "tun-stack-system": "tun:\n  enable: false\n  stack: system\n",
    "tun-stack-gvisor": "tun:\n  enable: false\n  stack: gvisor\n",
    "redir-port": "redir-port: 17891\n",
    "tproxy-port": "tproxy-port: 17892\n",
    "ipv6": "ipv6: true\n",
    "geodata-mode": "geodata-mode: true\n",
    "geodata-loader": "geodata-loader: standard\n",
    "unified-delay": "unified-delay: true\n",
    "tcp-concurrent": "tcp-concurrent: true\n",
    "find-process-mode-strict": "find-process-mode: strict\n",
    "profile-store-selected": "profile:\n  store-selected: true\n",
    "ebpf": "ebpf:\n  enable: false\n",
    "auto-redirect": "tun:\n  enable: false\n  auto-redirect: true\n",
    "dns-hijack": "tun:\n  enable: false\n  dns-hijack: ['any:53']\n",
    "fake-ip-range": "dns:\n  enable: false\n  fake-ip-range: 198.18.0.1/16\n",
    "fake-ip-filter-mode": "dns:\n  enable: false\n  fake-ip-filter-mode: blacklist\n",
    "direct-nameserver": "dns:\n  enable: false\n  direct-nameserver: [223.5.5.5]\n",
    "direct-nameserver-follow-policy": "dns:\n  enable: false\n  direct-nameserver-follow-policy: true\n",
    "nameserver-policy": "dns:\n  enable: false\n  nameserver-policy:\n    'geosite:cn': [223.5.5.5]\n",
    "respect-rules": "dns:\n  enable: false\n  respect-rules: true\n",
    "proxy-server-nameserver": "dns:\n  enable: false\n  proxy-server-nameserver: [223.5.5.5]\n",
    "tun-mtu": "tun:\n  enable: false\n  mtu: 9000\n",
    "listeners-inbound": """listeners:
  - name: in1
    type: mixed
    port: 17893
    listen: 127.0.0.1
""",
    "tunnels": """tunnels:
  - network: [tcp]
    address: 127.0.0.1:17894
    target: 8.8.8.8:53
    proxy: DIRECT
""",
    "rule-providers": """rule-providers:
  r1:
    type: http
    behavior: domain
    url: https://example.com/r.txt
    path: ./r.yaml
    interval: 86400
""",
    "proxy-providers": """proxy-providers:
  p1:
    type: http
    url: https://example.com/p.yaml
    path: ./p.yaml
    interval: 86400
    health-check:
      enable: true
      url: http://www.gstatic.com/generate_204
""",
    "sniffer": """sniffer:
  enable: true
  sniff:
    HTTP: {ports: [80, 8080]}
    TLS: {ports: [443, 8443]}
  override-destination: true
""",
    "hosts": "hosts:\n  'a.com': 1.2.3.4\n",
    "profile-store-fakeip": "profile:\n  store-fake-ip: true\n",
    "global-client-fingerprint": "global-client-fingerprint: chrome\n",
    "keep-alive-interval": "keep-alive-interval: 30\n",
    "find-process-mode-off": "find-process-mode: off\n",
    "interface-name": "interface-name: eth0\n",
    "routing-mark": "routing-mark: 255\n",
    "allow-lan": "allow-lan: true\n",
}


def test(name, yaml_text):
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False,
                                     encoding="utf-8") as f:
        f.write(yaml_text)
        path = f.name
    try:
        p = subprocess.run([BIN, "-t", "-d", os.path.dirname(path),
                            "-f", path],
                           capture_output=True, text=True, timeout=60)
        ok = p.returncode == 0
        err = (p.stderr or p.stdout or "").strip().splitlines()
        msg = err[-1][:100] if err else ""
        return ok, msg
    except subprocess.TimeoutExpired:
        return False, "timeout"
    finally:
        os.unlink(path)


def main():
    print(f"binary: {BIN}\n")
    print("=== 协议支持（proxies[].type）===")
    for name, frag in PROXIES.items():
        pname = frag.split("\n")[0].split("- name:")[-1].strip()
        yaml_text = BASE.format(proxies=frag, names='"%s", DIRECT' % pname)
        ok, msg = test(name, yaml_text)
        print(f"  {'YES' if ok else 'no ':4} {name:20} {'' if ok else msg}")

    print("\n=== 顶层配置项 ===")
    for name, frag in TOPLEVEL.items():
        yaml_text = BASE.format(proxies="", names="DIRECT") + frag
        ok, msg = test(name, yaml_text)
        print(f"  {'YES' if ok else 'no ':4} {name:34} {'' if ok else msg}")


if __name__ == "__main__":
    main()