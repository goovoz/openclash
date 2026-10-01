#!/bin/bash
# Inline awk test for CRLF.
set +e
echo "=== TEST: inline awk on CRLF CMakeLists ==="
awk -v nm=SOURCES '
BEGIN { cap = 0 }
$0 ~ "^SET\\(" nm "([ \t]|$)" { cap = 1; next }
cap {
    line = $0
    sub(/\).*$/, "", line)
    gsub(/[ \t]/, "", line)
    if (line != "") print line
    if ($0 ~ /\)/) cap = 0
}' /opt/openclash-rt/vendor/libnl-tiny/CMakeLists.txt

echo "=== TEST: with CRLF stripped first ==="
TMPF=/tmp/libnl-crlf-test.txt
tr -d '\r' < /opt/openclash-rt/vendor/libnl-tiny/CMakeLists.txt > "$TMPF"
awk -v nm=SOURCES '
BEGIN { cap = 0 }
$0 ~ "^SET\\(" nm "([ \t]|$)" { cap = 1; next }
cap {
    line = $0
    sub(/\).*$/, "", line)
    gsub(/[ \t]/, "", line)
    if (line != "") print line
    if ($0 ~ /\)/) cap = 0
}' "$TMPF"

echo "=== TEST: each line format ==="
sed -n '8p' /opt/openclash-rt/vendor/libnl-tiny/CMakeLists.txt | od -c | head -1