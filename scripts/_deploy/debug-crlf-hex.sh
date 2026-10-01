#!/bin/bash
set +e
F=/opt/openclash-rt/vendor/libnl-tiny/CMakeLists.txt
echo "=== line 11 hex (SET(SOURCES) ==="
sed -n '11p' "$F" | od -c | head -1
echo "=== line 12 hex (attr.c) ==="
sed -n '12p' "$F" | od -c | head -1
echo "=== awk: count lines matching /^SET/ ==="
awk '/^SET/' "$F" | wc -l
echo "=== awk: line 11 raw ==="
awk 'NR==11' "$F" | od -c | head -1
echo "=== awk: regex match with \r ==="
awk 'BEGIN {
    s = "SET(SOURCES\r"
    if (s ~ /^SET\(/) print "MATCH_CR"
    else print "NO_MATCH_CR"
    s2 = "SET(SOURCES"
    if (s2 ~ /^SET\(/) print "MATCH_NOCR"
    else print "NO_MATCH_NOCR"
}'