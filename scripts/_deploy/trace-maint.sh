#!/bin/bash
# Run test_maintainer_scripts with bash -x trace on A group.
set +e
cd /opt/openclash-rt
mkdir -p /tmp/maint-trace
# 用 -x 全程追踪 + 大输出，捕获 A 段的现场
bash -x tests/test_maintainer_scripts.sh 2>&1 > /tmp/maint-trace/all.log
# 抓出 case 6/7 周围的 trace
grep -B2 -A15 "有标记 + 链接不存在\|无标记 + 链接不存在" /tmp/maint-trace/all.log | head -80