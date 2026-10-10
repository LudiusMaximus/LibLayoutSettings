#!/usr/bin/env bash
# Runs every *_test.lua in this folder with whichever Lua is installed: Lua 5.1 or
# later, or LuaJIT. Exits 1 if any of them fails.

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

lua=$(command -v lua || command -v luajit || command -v lua5.1) \
  || { echo "No Lua interpreter found (lua, luajit or lua5.1)." >&2; exit 1; }

failed=0
for test in *_test.lua; do
  if out=$("$lua" "$test" 2>&1); then
    printf '%-22s %s\n' "$test" "$(printf '%s\n' "$out" | tail -n 1)"
  else
    printf '%-22s FAILED\n' "$test"
    printf '%s\n' "$out" | grep -E 'FAIL|error|traceback|\.lua:[0-9]+:' | sed 's/^/    /'
    failed=1
  fi
done
exit $failed
