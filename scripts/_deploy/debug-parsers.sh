#!/bin/bash
# Diagnose parsers on Debian.
set +e
. /opt/openclash-rt/runtime/lua/lib/upstream-parsers.sh
VENDOR=/opt/openclash-rt/vendor

echo "=== A1 libnl-tiny SOURCES ==="
A1="$(_cmake_setlist "$VENDOR/libnl-tiny/CMakeLists.txt" SOURCES)"
echo "A1=[$A1]"
echo "A1 line count:"
printf '%s\n' "$A1" | wc -l
echo "A1 first 3:"
printf '%s\n' "$A1" | head -3

echo "=== A2 liblucihttp ==="
A2C="$(_cmake_addlib "$VENDOR/lucihttp/CMakeLists.txt" liblucihttp)"
echo "A2C=[$A2C]"

echo "=== A2 liblucihttp-lua ==="
A2L="$(_cmake_addlib "$VENDOR/lucihttp/CMakeLists.txt" liblucihttp-lua)"
echo "A2L=[$A2L]"

echo "=== A3 nixio NIXIO_OBJ ==="
A3="$(_make_varlist "$VENDOR/luci/luci-lib-nixio/src/Makefile" NIXIO_OBJ)"
echo "A3=[$A3]" | head -c 300
echo

echo "=== function body: _cmake_setlist ==="
declare -f _cmake_setlist | head -30
echo "=== function body: _cmake_addlib ==="
declare -f _cmake_addlib | head -30