#!/bin/bash
# Reproduce test_maintainer_scripts A case 6.
set +e
WORK=/tmp/maint-debug
rm -rf "$WORK"; mkdir -p "$WORK/fs"
SB_ROOT="$WORK/fs"
SBIN_UCI_MARK="$SB_ROOT/.mark"
_TGT=/usr/sbin/uci

# Extract + rewrite path
SRC_RAW='rm_sbin_uci_if_ours() {
	[ -f "$SBIN_UCI_MARK" ] || return 0
	[ -L /sbin/uci ] || return 0
	_want="$(cat "$SBIN_UCI_MARK" 2>/dev/null || true)"
	[ -n "$_want" ] || return 0
	[ "$(readlink /sbin/uci 2>/dev/null || true)" = "$_want" ] || return 0
	rm -f /sbin/uci 2>/dev/null || true
}'

printf '%s\n' "$SRC_RAW" | sed "s,/sbin/uci,$SB_ROOT/uci,g" > "$WORK/pred.sh"

echo "=== rewritten function ==="
cat "$WORK/pred.sh"

echo "=== source ==="
. "$WORK/pred.sh"

echo "=== setup case 6: mark exists, link does not ==="
printf '%s\n' "$_TGT" > "$SBIN_UCI_MARK"
ls -la "$SB_ROOT"
echo "=== call ==="
rm_sbin_uci_if_ours
echo "RC=$?"
echo "=== after ==="
ls -la "$SB_ROOT"