#!/bin/bash
# Live review end to end on this Mac: a Vite + React app in its dev server, PointAndYap --live in front of it, a guest
# in real Chrome who points and talks (its fake microphone plays speech from `say`), the triage gate and --accept, an
# agent on the MCP that waits for the item, edits the source file the guest pointed at and marks it done, hot reload
# changing the guest's page, and the guest confirming it.
# Usage: bash relay/test/live-e2e.sh [app dir]   (needs Node and Google Chrome; LIVE_TUNNEL=1 goes through cloudflared)
set -euo pipefail
cd "$(dirname "$0")/../.."
swift build >/dev/null
B=$PWD/.build/debug/PointAndYap
T=$(mktemp -d -t pointandyap-live)
export POINTANDYAP_SESSIONS=$T/sessions
(cd relay/test && npm install --silent >/dev/null)
APP=${1:-}
if [ -z "$APP" ]; then
  (cd "$T" && npx --yes create-vite@6.5.0 app --template react-ts >/dev/null && cd app && npm install --silent >/dev/null)
  APP=$T/app
fi
cp "$APP/src/App.tsx" "$T/App.tsx.orig"
PORT=5174
(cd "$APP" && npx vite --port $PORT --strictPort >"$T/vite.log" 2>&1) &
VITE=$!
trap 'kill $VITE $LIVE 2>/dev/null; cp "$T/App.tsx.orig" "$APP/src/App.tsx"' EXIT
until curl -s -o /dev/null "http://localhost:$PORT"; do sleep 0.5; done

"$B" --live $PORT --from Owner $([ -n "${LIVE_TUNNEL:-}" ] || echo --no-tunnel) >"$T/live.log" 2>&1 &
LIVE=$!
until grep -q "__pay/k/" "$T/live.log"; do sleep 0.5; done
LINK=$(grep -o 'https\?://[^ ]*/__pay/k/[A-Za-z0-9_-]*' "$T/live.log" | head -1)
echo "link: $LINK"

say -o "$T/guest.wav" --data-format=LEI16@48000 "This counter button should be green."
node relay/test/live-guest.mjs "$LINK" "$T/guest.wav" "$T" both >"$T/guest.log" 2>&1 &
GUEST=$!

# The owner accepts what the guest asked for (it waits in triage until then).
for _ in $(seq 1 60); do ITEM=$("$B" --items | grep -m1 '\[triage\] from Dana' | cut -d' ' -f2 || true); [ -n "$ITEM" ] && break; sleep 1; done
[ -n "$ITEM" ] || { cat "$T/guest.log"; echo "FAIL: no item from the guest"; exit 1; }
"$B" --items | grep -q 'drawn at `src/App.tsx:' || { "$B" --items; echo "FAIL: the point has no source line"; exit 1; }
"$B" --accept "$ITEM"

node relay/test/live-agent.mjs "$B" "$APP"
wait $GUEST || { cat "$T/guest.log"; echo "FAIL: the guest did not see and confirm the fix"; exit 1; }
cat "$T/guest.log"
grep -q '"confirmed"' "$POINTANDYAP_SESSIONS/${ITEM%%#*}/state.json" || { echo "FAIL: not confirmed in state.json"; exit 1; }
echo "PASS ($T)"
