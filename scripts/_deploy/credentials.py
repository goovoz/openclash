"""
敏感配置统一从环境变量读取 —— 禁止硬编码凭据。

2026-10-02 修正：此前 scripts/_deploy/ui-*.py 硬编码了两台测试机的
内网地址与 root 口令，并已 push 到远端。私有仓库同样不该把凭据写进
代码—— git 历史里长期留存，且容易被克隆 / 备份 / 误转公开。
本文件自身也不写任何真实地址与口令，只描述用法。

用法：
    export OCRT_DEBIAN_URL=http://<debian-host>:9080
    export OCRT_DEBIAN_PWD='<luci-password>'
    export OCRT_OPENWRT_URL=http://<openwrt-host>
    export OCRT_OPENWRT_PWD='<luci-password>'
    python scripts/_deploy/ui-full-regress.py

不设环境变量时脚本会明确报缺哪个变量，而不是静默用默认值。
"""

import os
import sys


def _need(name: str, hint: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        sys.exit(
            f"[缺环境变量] {name}未设置。\n"
            f"  {hint}\n"
            f"  示例： export {name}='...'\n"
            f"  （凭据不再硬编码在脚本里，见 scripts/_deploy/credentials.py）"
        )
    return v


# --- openclash-rt（Debian）-------------------------------------------------
DEBIAN_URL = _need("OCRT_DEBIAN_URL", "openclash-rt 的 Web UI 根地址（含端口）")
DEBIAN_USER = os.environ.get("OCRT_DEBIAN_USER", "root")
DEBIAN_PWD = _need("OCRT_DEBIAN_PWD", "openclash-rt 的 LuCI 登录口令")

# --- 对照机（OpenWrt / ImmortalWrt）-----------------------------------------
# 仅双机对照脚本需要；单目标脚本不碰这些。
OPENWRT_URL = os.environ.get("OCRT_OPENWRT_URL", "")
OPENWRT_USER = os.environ.get("OCRT_OPENWRT_USER", "root")
OPENWRT_PWD = os.environ.get("OCRT_OPENWRT_PWD", "")

# --- 登录框选择器（两边 LuCI 世代不同）--------------------------------------
#   Debian 侧：openwrt-21.02 世代 → #luci_username
#   OpenWrt 侧：24.10 + ArgonTheme→ #cbi-input-user
SEL_DEBIAN = ("#luci_username", "#luci_password")
SEL_OPENWRT = ("#cbi-input-user", "#cbi-input-password")


def targets(need_openwrt: bool = False):
    """构造 (tag, base, (user_sel, pwd_sel), user, pwd) 列表。"""
    out = [("debian", DEBIAN_URL, SEL_DEBIAN, DEBIAN_USER, DEBIAN_PWD)]
    if need_openwrt:
        if not (OPENWRT_URL and OPENWRT_PWD):
            sys.exit(
                "[缺环境变量] 双机对照需要 OCRT_OPENWRT_URL 与 OCRT_OPENWRT_PWD。\n"
                "  示例： export OCRT_OPENWRT_URL=http://<openwrt-host>"
            )
        out.append(("openwrt", OPENWRT_URL, SEL_OPENWRT, OPENWRT_USER, OPENWRT_PWD))
    return out
