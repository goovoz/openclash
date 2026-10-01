#!/bin/bash
set +e
cd /opt/openclash-rt
UCI=upstream/luci-app-openclash/root/etc/uci-defaults/luci-openclash

echo "=== awk on CRLF ==="
awk '
    /^case "\$\{DISTRIB_ARCH\}" in/ { inside=1 }
    inside { print NR": "$0 }
    inside && /^esac/ { exit }
' "$UCI" | head -30

echo "=== awk on CRLF, lines count ==="
awk '
    /^case "\$\{DISTRIB_ARCH\}" in/ { inside=1 }
    inside { print }
    inside && /^esac/ { exit }
' "$UCI" | wc -l

echo "=== awk after tr -d \\r ==="
tr -d '\r' < "$UCI" > /tmp/uci-no-crlf
awk '
    /^case "\$\{DISTRIB_ARCH\}" in/ { inside=1 }
    inside { print }
    inside && /^esac/ { exit }
' /tmp/uci-no-crlf | wc -l