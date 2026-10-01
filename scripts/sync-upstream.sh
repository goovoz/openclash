#!/usr/bin/env bash
# =============================================================================
# 上游同步脚本
# -----------------------------------------------------------------------------
# 职责：
#   1. 拉取 upstream (vernesong/OpenClash) 指定分支到 upstream/
#   2. 记录版本号与 commit（供 .deb 的 Version 字段与可追溯性使用）
#   3. 依次 apply patches/*.patch —— 失败立即退出（CI 据此告警）
#   4. 输出一份「上游变更摘要」，便于人工判断是否需要新增 patch
#
# 设计红线：L1 上游代码保持原样，所有适配优先落在 runtime/（兼容运行时）。
#           patches/ 只允许放「无法用运行时吸收」的改动，且必须附理由。
#
# 用法：
#   scripts/sync-upstream.sh                 # 默认 master
#   scripts/sync-upstream.sh dev
#   UPSTREAM_REPO=... scripts/sync-upstream.sh
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="${1:-master}"
REPO="${UPSTREAM_REPO:-https://github.com/vernesong/OpenClash.git}"
SPARSE_PATH="luci-app-openclash"
DEST="$ROOT/upstream"
CHECKOUT="$DEST/.checkout"
VER_FILE="$DEST/.upstream-version"
PATCH_DIR="$ROOT/patches"

log()  { printf '\033[1;36m[sync]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; }

mkdir -p "$DEST"

# --- 1. 拉取 -----------------------------------------------------------------
# 优先 git（能拿到 commit/变更历史）；失败则回退到 codeload tarball。
# 不使用 --filter=blob:none：在受限网络下按需取 blob 容易踩代理隧道错误。
fetch_git() {
	rm -rf "$CHECKOUT"
	if git clone --depth 1 --branch "$BRANCH" --sparse "$REPO" "$CHECKOUT" 2>/dev/null; then
		git -C "$CHECKOUT" sparse-checkout set "$SPARSE_PATH" 2>/dev/null || true
		return 0
	fi
	return 1
}

fetch_tarball() {
	local url="https://codeload.github.com/vernesong/OpenClash/tar.gz/refs/heads/$BRANCH"
	local tmp="$DEST/.tarball.$$"
	log "git 不可用，回退 tarball: $url"
	rm -rf "$CHECKOUT" "$tmp"
	mkdir -p "$tmp" "$CHECKOUT"
	curl -fsSL --connect-timeout 30 --retry 2 "$url" -o "$tmp/o.tar.gz" || return 1
	tar xzf "$tmp/o.tar.gz" -C "$CHECKOUT" --strip-components=1 || return 1
	rm -rf "$tmp"
	return 0
}

if [ ! -d "$CHECKOUT/.git" ] && [ ! -d "$CHECKOUT/$SPARSE_PATH" ]; then
	log "首次获取 $REPO ($BRANCH)"
	fetch_git || fetch_tarball || { err "拉取上游失败"; exit 1; }
elif [ -d "$CHECKOUT/.git" ]; then
	log "增量更新 $BRANCH"
	if git -C "$CHECKOUT" fetch --depth 1 origin "$BRANCH" 2>/dev/null; then
		git -C "$CHECKOUT" reset --hard FETCH_HEAD 2>/dev/null || true
		git -C "$CHECKOUT" sparse-checkout set "$SPARSE_PATH" 2>/dev/null || true
	else
		warn "增量拉取失败，回退全量 tarball"
		fetch_tarball || { err "拉取上游失败"; exit 1; }
	fi
else
	log "复用已存在的 checkout"
fi

if [ -d "$CHECKOUT/.git" ]; then
	COMMIT="$(git -C "$CHECKOUT" rev-parse HEAD)"
	SHORT="$(git -C "$CHECKOUT" rev-parse --short HEAD)"
	DATE="$(git -C "$CHECKOUT" log -1 --format=%cI)"
	SUBJECT="$(git -C "$CHECKOUT" log -1 --format=%s)"
else
	COMMIT="unknown"
	SHORT="unknown"
	DATE="$(date -Iseconds)"
	SUBJECT="(tarball 快照，无 git 元数据)"
fi

# 上游版本号取自 luci-app-openclash/Makefile 的 PKG_VERSION
MK="$CHECKOUT/$SPARSE_PATH/Makefile"
PKG_VER=""
if [ -f "$MK" ]; then
	PKG_VER="$(sed -n 's/^PKG_VERSION:=\(.*\)/\1/p' "$MK" | head -1 | tr -d ' ')"
	PKG_REL="$(sed -n 's/^PKG_RELEASE:=\(.*\)/\1/p' "$MK" | head -1 | tr -d ' ')"
fi
log "上游 commit=$SHORT  PKG_VERSION=${PKG_VER:-?}  PKG_RELEASE=${PKG_REL:-?}"
log "最新提交: $SUBJECT"

# --- 2. 同步文件到 upstream/ -------------------------------------------------
# 保留 .checkout 作为 git 工作区，upstream/luci-app-openclash 作为「可用副本」
# ⚠️ ${DEST:?} 与 ${SPARSE_PATH:?} 是**必须的**（shellcheck SC2115）：这两个变量
#   任一为空，`rm -rf "$DEST/$SPARSE_PATH"` 就退化成 `rm -rf "/xxx"` 甚至
#    `rm -rf /` —— 而本脚本天天由 CI 无人值守地跑，没有交互确认兜底。
#   用 :? 让它在空值时**立即失败**并打印变量名，而不是去删根目录。
rm -rf "${DEST:?}/$(printf '%s' "${SPARSE_PATH:?}")"
cp -a "$CHECKOUT/${SPARSE_PATH:?}" "$DEST/${SPARSE_PATH:?}"

cat >"$VER_FILE" <<EOF
BRANCH=$BRANCH
COMMIT=$COMMIT
SHORT=$SHORT
DATE=$DATE
PKG_VERSION=${PKG_VER:-}
PKG_RELEASE=${PKG_REL:-0}
SUBJECT=$SUBJECT
EOF

# --- 3. 应用补丁 -------------------------------------------------------------
PATCH_FAILED=0
if compgen -G "$PATCH_DIR/*.patch" >/dev/null; then
	log "应用补丁 ..."
	for p in "$PATCH_DIR"/*.patch; do
		name="$(basename "$p")"
		case "$name" in
			*.README*|README*) continue ;;
		esac
		if git -C "$DEST/$SPARSE_PATH" apply --check "$p" 2>/dev/null; then
			git -C "$DEST/$SPARSE_PATH" apply "$p"
			log "  ✓ $name"
		elif git -C "$DEST/$SPARSE_PATH" apply --check --reverse "$p" 2>/dev/null; then
			log "  = $name (已应用过)"
		else
			err "  ✗ $name 应用失败 —— 上游大概率改动了相关代码"
			PATCH_FAILED=1
		fi
	done
else
	log "patches/ 为空 —— 全部适配由 runtime/ 兼容层承担（理想状态）"
fi

# --- 4. 变更摘要 -------------------------------------------------------------
PREV="$DEST/.upstream-commit.prev"
if [ -f "$PREV" ] && [ "$(cat "$PREV")" != "$COMMIT" ]; then
	log "上游自 $(cat "$PREV" | cut -c1-8) 起的变更："
	git -C "$CHECKOUT" log --oneline --no-merges \
		"$(cat "$PREV")..$COMMIT" 2>/dev/null | head -30 || warn "无法生成变更列表（历史被 depth 截断）"
fi
printf '%s\n' "$COMMIT" >"$PREV"

# --- 5. 退出码 ---------------------------------------------------------------
if [ "$PATCH_FAILED" -ne 0 ]; then
	err "补丁冲突 —— 需要人工介入，禁止静默继续"
	exit 2
fi

log "完成。版本信息写入 $VER_FILE"
exit 0
