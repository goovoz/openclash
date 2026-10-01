#!/bin/bash
set +e
WORK=/tmp/owl-debug
rm -rf "$WORK"; mkdir -p "$WORK"
UP="$WORK/upstream_core_arch.sh"
UCI_DEFAULTS=/opt/openclash-rt/upstream/luci-app-openclash/root/etc/uci-defaults/luci-openclash

{
    printf "#!/bin/sh\n"
    printf 'DISTRIB_ARCH="$1"\n'
    printf 'CORE_ARCH=""\n'
    awk '
        /^case "\$\{DISTRIB_ARCH\}" in/ { inside=1 }
        inside { print }
        inside && /^esac/ { exit }
    ' "$UCI_DEFAULTS"
    printf 'printf "%%s" "$CORE_ARCH"\n'
} > "$UP"
chmod +x "$UP"
echo "=== upstream script ==="
sed -n '1,15p' "$UP"
echo "..."
echo "=== call up_core x86_64 ==="
sh "$UP" "x86_64"; echo
echo "=== call up_core aarch64_generic ==="
sh "$UP" "aarch64_generic"; echo
echo "=== call up_core arm_cortex-a7 ==="
sh "$UP" "arm_cortex-a7"; echo
echo "=== call up_core loongarch64_generic ==="
sh "$UP" "loongarch64_generic"; echo
echo "=== call up_core unknown_xyz ==="
sh "$UP" "unknown_xyz"; echo