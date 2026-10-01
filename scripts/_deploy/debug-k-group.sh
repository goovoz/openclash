#!/usr/bin/env bash
# Reproduce K-group assertions on local MSYS to compare against Debian.
set +e
ROOT="C:/Users/HHH/Documents/openclash 改造任意服务器端"
ROOT="$(cygpath -u "$ROOT")"
PIN="$ROOT/runtime/upstream/pin-lua-interpreter.sh"
SRC="$ROOT/vendor/luci/luci-base/htdocs/cgi-bin/luci"
LUCI_RPC="$ROOT/vendor/luci/luci-base/root/usr/libexec/rpcd/luci"
WORK=/tmp/k-debug-msys
rm -rf "$WORK"; mkdir -p "$WORK/K" "$WORK/K-dry"
cp "$SRC" "$WORK/K/cgi-luci"
cp "$LUCI_RPC" "$WORK/K/rpcd-luci"
cp "$SRC" "$WORK/K-dry/cgi"

echo "=== file format ==="
file "$SRC"

echo "=== step: pin ==="
bash "$PIN" --file "$WORK/K/cgi-luci" --file "$WORK/K/rpcd-luci"
echo "RC=$?"

echo "=== step: dry-run ==="
bash "$PIN" --file "$WORK/K-dry/cgi" --dry-run
echo "RC=$?"

echo "=== head -1 hex on K-dry/cgi ==="
head -1 "$WORK/K-dry/cgi" | od -c | head -1

echo "=== chk expected value ==="
echo -n "#!/usr/bin/lua" | od -c | head -1