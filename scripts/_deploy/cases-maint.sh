#!/bin/bash
# Manually run all 7 A-cases on Debian.
set +e
WORK=/tmp/maint-cases
rm -rf "$WORK"; mkdir -p "$WORK"
SB_ROOT="$WORK/fs"
SBIN_UCI_MARK="$SB_ROOT/.mark"
_TGT=/usr/sbin/uci
_OTHER=/usr/bin/other-uci

# Extract and rewrite
PRERM=/opt/openclash-rt/packaging/debian/prerm
SRC="$(sed -n '/^rm_sbin_uci_if_ours() {$/,/^}$/p' "$PRERM" | sed "s,/sbin/uci,$SB_ROOT/uci,g")"
printf '%s\n' "$SRC" > "$WORK/pred.sh"
. "$WORK/pred.sh"

_check() {
    local desc="$1" want="$2" got
    if [ ! -e "$SB_ROOT/uci" ] && [ ! -L "$SB_ROOT/uci" ]; then got=gone; else got=kept; fi
    if [ "$got" = "$want" ]; then echo "PASS $desc"; else echo "FAIL $desc got=$got want=$want"; fi
}

# Case 1: 无标记 + 链接存在
rm -rf "$SB_ROOT"; mkdir -p "$SB_ROOT"
ln -s "$_TGT" "$SB_ROOT/uci"
rm_sbin_uci_if_ours
_check "case1 no-mark+link-exists kept" kept

# Case 2: 有标记 + 指向记录目标
rm -rf "$SB_ROOT"; mkdir -p "$SB_ROOT"
ln -s "$_TGT" "$SB_ROOT/uci"; printf '%s\n' "$_TGT" > "$SBIN_UCI_MARK"
rm_sbin_uci_if_ours
_check "case2 mark+target-link gone" gone

# Case 3: 有标记 + 链接被改指别处
rm -rf "$SB_ROOT"; mkdir -p "$SB_ROOT"
ln -s "$_OTHER" "$SB_ROOT/uci"; printf '%s\n' "$_TGT" > "$SBIN_UCI_MARK"
rm_sbin_uci_if_ours
_check "case3 mark+other-link kept" kept

# Case 4: 有标记 + 是真实文件
rm -rf "$SB_ROOT"; mkdir -p "$SB_ROOT"
: >"$SB_ROOT/uci"; printf '%s\n' "$_TGT" > "$SBIN_UCI_MARK"
rm_sbin_uci_if_ours
_check "case4 mark+real-file kept" kept

# Case 5: 有标记但内容为空
rm -rf "$SB_ROOT"; mkdir -p "$SB_ROOT"
ln -s "$_TGT" "$SB_ROOT/uci"; : >"$SBIN_UCI_MARK"
rm_sbin_uci_if_ours
_check "case5 mark-empty kept" kept

# Case 6: 有标记 + 链接不存在
rm -rf "$SB_ROOT"; mkdir -p "$SB_ROOT"
printf '%s\n' "$_TGT" > "$SBIN_UCI_MARK"
ls -la "$SB_ROOT" | head -5
rm_sbin_uci_if_ours
echo "RC=$?"
ls -la "$SB_ROOT" | head -5
_check "case6 mark+no-link kept" kept

# Case 7: 无标记 + 链接不存在
rm -rf "$SB_ROOT"; mkdir -p "$SB_ROOT"
rm_sbin_uci_if_ours
_check "case7 no-mark+no-link kept" kept