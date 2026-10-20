#!/usr/bin/env bash
# Bridge ID 24 S5 — the OUTSIDE uptime check, GitHub Actions edition (docs/UPTIME-ALERTS.md §3). The same rules as
# scripts/uptime-check.ps1 on Dimitris's PC, but it runs on GitHub's machines, so it works with the PC off:
#   «up» = HTTP 200 and JSON "ok":true within 15 s ("frozen":true counts as up, with a note);
#   a target that fails, is re-checked after $RECHECK_SECONDS (default 60) and fails again is DOWN — that is the
#   «2 failed checks in a row» — and sends ONE ntfy alert; its first good check afterwards sends ONE «recovered».
# State: one file per target in $STATE_DIR («up» / «down»). The workflow commits that folder only when it changes, so
# an outage alerts once, not every 5 minutes.
# The ntfy topic is a secret: read from $NTFY_TOPIC (a repository secret), never printed. Unset = dry run («would send»).
# Exit 0 always: a red run is not the alert, the ntfy message is.
# Usage: check.sh <url> [<url> …]
set -u
STATE_DIR="${STATE_DIR:-state}"
RECHECK_SECONDS="${RECHECK_SECONDS:-60}"
NTFY_BASE="${NTFY_BASE:-https://ntfy.sh}"
mkdir -p "$STATE_DIR"

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

notify() {   # $1 title, $2 message
  if [ -z "${NTFY_TOPIC:-}" ]; then echo "ntfy: (dry run, no topic) would send «$1»"; return; fi
  local body
  body="{\"topic\":\"$(json_escape "$NTFY_TOPIC")\",\"title\":\"$(json_escape "$1")\",\"message\":\"$(json_escape "$2")\",\"priority\":4,\"tags\":[\"warning\"]}"
  if curl -sS -m 15 -o /dev/null -H 'Content-Type: application/json' --data-binary "$body" "$NTFY_BASE/" 2>/dev/null; then
    echo "ntfy: sent «$1»"
  else
    echo "ntfy: failed"
  fi
}

# probe <url> → prints «up», «up frozen» or «down <why>»
probe() {
  local tmp code
  tmp="$(mktemp)"
  code="$(curl -sS -m 15 -o "$tmp" -w '%{http_code}' "$1" 2>/dev/null)" || code="${code:-000}"
  if [ "$code" != "200" ]; then rm -f "$tmp"; echo "down HTTP ${code:-000}"; return; fi
  if ! tr -d ' \r\n\t' < "$tmp" | grep -q '"ok":true'; then rm -f "$tmp"; echo "down ok is not true"; return; fi
  if tr -d ' \r\n\t' < "$tmp" | grep -q '"frozen":true'; then rm -f "$tmp"; echo "up frozen"; return; fi
  rm -f "$tmp"; echo "up"
}

for url in "$@"; do
  name="$(printf '%s' "$url" | sed -e 's#^[a-z]*://##' -e 's#[^A-Za-z0-9._-]#_#g')"
  file="$STATE_DIR/$name"
  prev="$(cat "$file" 2>/dev/null || echo up)"
  r="$(probe "$url")"
  if [ "${r%% *}" = "down" ]; then
    sleep "$RECHECK_SECONDS"
    r2="$(probe "$url")"
    if [ "${r2%% *}" = "down" ]; then
      echo "$url: DOWN — ${r#down } / ${r2#down } (2 checks in a row)"
      if [ "$prev" != "down" ]; then
        notify "Nutrition Hero: εκτός λειτουργίας" "$url δεν απαντά (${r2#down }), 2 έλεγχοι στη σειρά."
        echo down > "$file"
      fi
      continue
    fi
    r="$r2"
  fi
  echo "$url: up${r#up}"
  if [ "$prev" = "down" ]; then notify "Nutrition Hero: ξανά σε λειτουργία" "$url απαντά ξανά."; fi
  echo up > "$file"
done
exit 0
