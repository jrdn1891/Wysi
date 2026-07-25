#!/bin/sh
set -e
cd "$(dirname "$0")/.."
python3 -m http.server 8799 --bind 127.0.0.1 >/dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null' EXIT
sleep 1
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
fail=0
run_page() {
  out=$("$chrome" --headless=new --disable-gpu --dump-dom --virtual-time-budget=30000 \
    --disable-features=IsolateSandboxedIframes \
    --host-resolver-rules="MAP * 127.0.0.1, EXCLUDE localhost" \
    $2 \
    "http://localhost:8799/spike/$1.html" 2>/dev/null)
  if printf '%s' "$out" | grep -q 'SPIKE-PASS'; then
    echo "$3: PASS"
  else
    echo "$3: FAIL"
    printf '%s\n' "$out" | head -c 6000
    fail=1
  fi
}
for page in paths agent slides stacked-slides overlay-slides theme format laser film; do
  run_page "$page" "" "$page"
done
run_page laser --force-device-scale-factor=2 "laser@2x"
exit $fail
