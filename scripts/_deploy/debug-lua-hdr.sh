#!/bin/bash
# Test Lua header regex match precisely.
set +e

echo "=== test 1: literal 'LUA_VERSION_NUM[TAB]501' ==="
printf '#define LUA_VERSION_NUM\t501\n' > /tmp/lualine.txt
od -c /tmp/lualine.txt | head -1
grep -qE '^#[ \t]*define[ \t]+LUA_VERSION_NUM[ \t]+501' /tmp/lualine.txt && echo MATCH || echo NO_MATCH

echo "=== test 2: literal 'LUA_VERSION_NUM SPACE 501' ==="
printf '#define LUA_VERSION_NUM 501\n' > /tmp/lualine2.txt
od -c /tmp/lualine2.txt | head -1
grep -qE '^#[ \t]*define[ \t]+LUA_VERSION_NUM[ \t]+501' /tmp/lualine2.txt && echo MATCH || echo NO_MATCH

echo "=== test 3: real lua.h line ==="
grep "LUA_VERSION_NUM" /usr/include/lua5.1/lua.h | od -c | head -2
grep -qE '^#[ \t]*define[ \t]+LUA_VERSION_NUM[ \t]+501' /usr/include/lua5.1/lua.h && echo MATCH || echo NO_MATCH

echo "=== test 4: real line with -E, different anchor ==="
grep -E 'LUA_VERSION_NUM' /usr/include/lua5.1/lua.h | grep -E '^[ \t]*#[ \t]*define' | head -1

echo "=== test 5: POSIX behavior of [ \\t]+ in BRE/ERE ==="
printf 'a\tb\n' | grep -qE '^[ \t]+b' && echo MATCH || echo NO_MATCH
printf 'a b\n'  | grep -qE '^[ \t]+b' && echo MATCH || echo NO_MATCH

echo "=== test 6: anchored check on real header ==="
head -25 /usr/include/lua5.1/lua.h | grep -nE 'LUA_VERSION_NUM'