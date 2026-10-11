#!/usr/bin/env bash
# Runs every *_test.lua in this folder with whichever Lua is installed: Lua 5.1 or
# later, or LuaJIT. Exits 1 if any of them fails.
#
# Each test also stops itself if it runs away (see the watchdog in stubs.lua).
# The time limit here is the backstop for what that cannot catch.

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

lua=$(command -v lua || command -v luajit || command -v lua5.1) \
  || { echo "No Lua interpreter found (lua, luajit or lua5.1)." >&2; exit 1; }

# A Scoop shim only launches the real interpreter as a child, and stopping the
# shim can leave that child running. So run the interpreter the shim points to.
shim="${lua%.exe}.shim"
if [ -f "$shim" ]; then
  target=$(sed -n 's/^path = "\(.*\)"/\1/p' "$shim" | tr -d '\r')
  [ -n "$target" ] && lua=$(cygpath -u "$target" 2>/dev/null || echo "$target")
fi

failed=0
for test in *_test.lua; do
  if out=$(timeout 60 "$lua" "$test" 2>&1); then
    printf '%-22s %s\n' "$test" "$(printf '%s\n' "$out" | tail -n 1)"
  else
    printf '%-22s FAILED\n' "$test"
    printf '%s\n' "$out" | grep -E 'FAIL|WATCHDOG|error|traceback|\.lua:[0-9]+:' | sed 's/^/    /'
    failed=1
  fi
done
exit $failed
