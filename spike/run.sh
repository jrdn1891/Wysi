#!/bin/sh
set -e
cd "$(dirname "$0")/.."
python3 -m http.server 8799 --bind 127.0.0.1 >/dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null' EXIT
sleep 1
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
fail=0
for page in paths agent slides stacked-slides overlay-slides theme film; do
  out=$("$chrome" --headless=new --disable-gpu --dump-dom --virtual-time-budget=30000 \
    --disable-features=IsolateSandboxedIframes \
    --host-resolver-rules="MAP * 127.0.0.1, EXCLUDE localhost" \
    "http://localhost:8799/spike/$page.html" 2>/dev/null)
  if printf '%s' "$out" | grep -q 'SPIKE-PASS'; then
    echo "$page: PASS"
  else
    echo "$page: FAIL"
    printf '%s\n' "$out" | head -c 6000
    fail=1
  fi
done
exit $fail
