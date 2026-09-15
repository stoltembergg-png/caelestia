#!/usr/bin/env bash
# Probe ai-memory: HTTP API when available, CLI status as fallback.
# Usage: ai-memory-probe.sh [endpoint] [workspace] [project]
set -u

EP="${1:-http://127.0.0.1:49374}"
WS="${2:-}"
PROJ="${3:-}"
HOME_DIR="${HOME:-/tmp}"
AI="${AI_MEMORY_BIN:-$HOME_DIR/.local/bin/ai-memory}"
DD="${AI_MEMORY_DATA_DIR:-$HOME_DIR/.local/share/ai-memory}"
CFG="${AI_MEMORY_CONFIG:-$HOME_DIR/.config/ai-memory/config.toml}"

cli="null"
if [ -x "$AI" ]; then
  raw=$("$AI" --data-dir "$DD" --config "$CFG" status --json 2>/dev/null)
  if [ -n "$raw" ] && printf %s "$raw" | jq -e . >/dev/null 2>&1; then
    cli="$raw"
  fi
fi

projects=$(curl -s -m 2 "$EP/api/v1/projects" 2>/dev/null)
if [ -z "$projects" ] || ! printf %s "$projects" | jq -e . >/dev/null 2>&1; then
  if [ "$cli" = "null" ]; then
    echo '{"server":false,"cli":null}'
  else
    jq -n --argjson cli "$cli" '{server:false, cli:$cli}'
  fi
  exit 0
fi

ws="$WS"
[ -z "$ws" ] && ws=$(printf %s "$projects" | jq -r '.[0].workspace_name // "default"')
proj="$PROJ"
if [ -z "$proj" ]; then
  proj=$(printf %s "$projects" | jq -r '([.[] | select((.page_count // 0) > 0)] | sort_by(.last_updated) | reverse | .[0].project_name) // (.[0].project_name // "")')
fi

wsenc=$(printf %s "$ws" | jq -sRr @uri)
projenc=$(printf %s "$proj" | jq -sRr @uri)

overview=$(curl -s -m 2 "$EP/api/v1/workspaces/$wsenc/overview?limit=10" 2>/dev/null)
printf %s "${overview:-null}" | jq -e . >/dev/null 2>&1 || overview="null"

handoffs="null"
recent="null"
if [ -n "$proj" ]; then
  handoffs=$(curl -s -m 2 "$EP/api/v1/workspaces/$wsenc/projects/$projenc/handoffs?state=open&limit=20" 2>/dev/null)
  recent=$(curl -s -m 2 "$EP/api/v1/workspaces/$wsenc/projects/$projenc/recent?limit=8" 2>/dev/null)
fi
printf %s "${handoffs:-null}" | jq -e . >/dev/null 2>&1 || handoffs="null"
printf %s "${recent:-null}" | jq -e . >/dev/null 2>&1 || recent="null"

cost=$(kodexbar-quotas cost --format json --json-only 2>/dev/null)
printf %s "${cost:-[]}" | jq -e . >/dev/null 2>&1 || cost="[]"
cost_trim=$(printf %s "$cost" | jq -c '[.[] | {provider: .provider, cost: (.last30DaysCostUSD // 0), projects: ((.projects // []) | map({name: (.name // .path // "?"), cost: (.totalCost // 0)}) | sort_by(.cost) | reverse | .[0:5])}]' 2>/dev/null)
[ -z "$cost_trim" ] && cost_trim="[]"

sessions="[]"
session_rows=$(printf %s "$projects" | jq -r '.[].project_name' | while IFS= read -r pn; do
  [ -z "$pn" ] && continue
  pne=$(printf %s "$pn" | jq -sRr @uri)
  curl -s -m 2 "$EP/api/v1/workspaces/$wsenc/projects/$pne/sessions?limit=10&include_open=true" 2>/dev/null \
    | jq -c --arg p "$pn" 'if (.sessions|type)=="array" then [.sessions[] | . + {project: $p}] else [] end' 2>/dev/null
done | jq -s 'add // [] | sort_by(.started_at) | reverse | .[0:20]' 2>/dev/null)
printf %s "${session_rows:-[]}" | jq -e . >/dev/null 2>&1 && sessions="$session_rows"

jq -n \
  --argjson cli "$cli" \
  --argjson projects "$projects" \
  --arg ws "$ws" --arg proj "$proj" \
  --argjson overview "${overview:-null}" \
  --argjson handoffs "${handoffs:-null}" \
  --argjson recent "${recent:-null}" \
  --argjson sessions "${sessions:-[]}" \
  --argjson cost "${cost_trim:-[]}" \
  '{server:true, cli:$cli, workspace:$ws, project:$proj, projects:$projects, overview:$overview, handoffs:(if ($handoffs|type) == "object" then ($handoffs.handoffs // []) else [] end), recent:(if ($recent|type) == "array" then $recent elif ($recent|type) == "object" then ($recent.pages // []) else [] end), sessions:$sessions, cost:$cost}'
