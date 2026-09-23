#!/usr/bin/env bash
#
# Solo Enterprise for agentgateway — standalone walkthrough
#
# Three acts, roughly 45 minutes, on the standalone binary. No Kubernetes.
#
#   Act 1 — The developer path        Coding agents through the gateway, model
#                                     steering, local models, failover that
#                                     actually fails over, and a guardrail that
#                                     catches sensitive data arriving in a TOOL
#                                     RESULT rather than only in the prompt.
#   Act 2 — Admin view and cost       Virtual keys per project, model allowlists,
#                                     warn-then-stop budgets, and the toolMode
#                                     flip that collapses a tool catalogue into
#                                     a single call.
#   Act 3 — Governance and audit      Federated MCP behind one governed door,
#                                     tool authorization, the audit record, the
#                                     admin UI behind OIDC, and RFC 8693
#                                     delegation naming both the agent and the
#                                     human it acted for.
#
# Every state shown is read from and applied from the SAME file:
# config/config.yaml. The proxy watches that file, so what is on screen is what
# is running. Every request prints the exact command and its real response.
#
# Usage:
#   ./demo.sh              # full interactive demo
#   ./demo.sh --act 2      # reset, fast-forward act 1 silently, play act 2
#   ./demo.sh --check      # non-interactive smoke test of every assertion
#   ./demo.sh --reset      # return to the Act 0 config
#
# Controls: press Enter to advance. Ctrl-C to exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${SCRIPT_DIR}/config/config.yaml"
ACTS="${SCRIPT_DIR}/config/acts"
LLM="http://localhost:4000"
MCP="http://localhost:3000"
UI="http://localhost:15000"
PRIMARY_CTL="http://localhost:18080"

K_CHECKOUT="sk-demo-checkout-api-7f3a9c"
K_MOBILE="sk-demo-mobile-app-2b8e41"
K_ANALYTICS="sk-demo-analytics-9d4c02"
K_PLATFORM="sk-demo-platform-eng-5a1f77"

###############################################################################
# Display helpers
###############################################################################
BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; RED='\033[0;31m'; MAGENTA='\033[0;35m'; WHITE='\033[1;37m'
NC='\033[0m'; BG_BLUE='\033[44m'

STEP_NUM=0
SILENT=false
CHECK_MODE=false
FAILURES=0

pause() {
  [ "$SILENT" = "true" ] && return 0
  [ "$CHECK_MODE" = "true" ] && return 0
  echo ""
  echo -en "  ${DIM}[ Press Enter to continue ]${NC}"
  read -r _ || true
  echo ""
}

act() {
  local num=$1; shift
  STEP_NUM=0
  if [ "$SILENT" = "true" ]; then
    echo -e "${DIM}▶ fast-forwarding Act ${num} — ${*}...${NC}"; return 0
  fi
  [ "$CHECK_MODE" = "true" ] && { echo ""; echo -e "${BOLD}### ACT ${num}: $*${NC}"; return 0; }
  clear 2>/dev/null || true
  echo ""
  echo -e "${BG_BLUE}${WHITE}                                                                        ${NC}"
  echo -e "${BG_BLUE}${WHITE}   ACT ${num}: $*${NC}"
  echo -e "${BG_BLUE}${WHITE}                                                                        ${NC}"
  echo ""
  pause
}

scene() {
  STEP_NUM=$((STEP_NUM + 1))
  [ "$SILENT" = "true" ] && return 0
  [ "$CHECK_MODE" = "true" ] && { echo -e "${DIM}-- ${STEP_NUM}. $*${NC}"; return 0; }
  echo ""
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${CYAN}  ${STEP_NUM}. $*${NC}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

narrate() { { [ "$SILENT" = "true" ] || [ "$CHECK_MODE" = "true" ]; } && return 0; echo -e "  ${DIM}$*${NC}"; }
callout() { { [ "$SILENT" = "true" ] || [ "$CHECK_MODE" = "true" ]; } && return 0; echo -e "  ${YELLOW}▸ $*${NC}"; }
quote()   { { [ "$SILENT" = "true" ] || [ "$CHECK_MODE" = "true" ]; } && return 0; echo -e "  ${MAGENTA}❝ $*${NC}"; }
check_ok(){ echo -e "  ${GREEN}✓ $*${NC}"; }
check_fail(){ echo -e "  ${RED}✗ $*${NC}"; FAILURES=$((FAILURES+1)); }

expect() {
  local label=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then
    printf "  ${GREEN}✓${NC} %-46s ${GREEN}%s${NC}\n" "$label" "$got"
  else
    printf "  ${RED}✗${NC} %-46s ${RED}%s${NC} ${DIM}(expected %s)${NC}\n" "$label" "$got" "$want"
    FAILURES=$((FAILURES+1))
  fi
}

# Like expect(), but colours a denial red so a block reads as a block from the
# back of the room, and carries the reason the gateway decided.
expect_why() {
  local label=$1 want=$2 got=$3 why=${4:-}
  local col="${GREEN}"
  case "$got" in 401|403|429) col="${RED}" ;; esac
  if [ "$want" = "$got" ]; then
    printf "  ${GREEN}✓${NC} %-40s ${col}%s${NC}  ${DIM}%s${NC}\n" "$label" "$got" "$why"
  else
    printf "  ${RED}✗${NC} %-40s ${RED}%s${NC}  ${DIM}(expected %s)${NC}\n" "$label" "$got" "$want"
    FAILURES=$((FAILURES+1))
  fi
}

show_send() { { [ "$SILENT" = "true" ] || [ "$CHECK_MODE" = "true" ]; } && return 0; echo -e "  ${CYAN}send ▸${NC} $*"; }

# Show a slice of the LIVE config file. The audience should see the YAML that is
# actually running, not a slide about it.
show_config() {
  local start=$1 lines=${2:-24}
  { [ "$SILENT" = "true" ] || [ "$CHECK_MODE" = "true" ]; } && { echo -e "  ${DIM}📄 config/config.yaml (${start})${NC}"; return 0; }
  echo -e "  ${BOLD}📄 config/config.yaml${NC} ${DIM}— the file the proxy is reading right now${NC}"
  echo -e "  ${MAGENTA}┌────────────────────────────────────────────────────────${NC}"
  awk -v pat="$start" -v n="$lines" 'index($0,pat){f=1} f&&c<n{print;c++}' "$CFG" \
    | while IFS= read -r line; do printf '  %b│%b %s\n' "$MAGENTA" "$NC" "$line"; done
  echo -e "  ${MAGENTA}└────────────────────────────────────────────────────────${NC}"
}

ui_moment() {
  { [ "$SILENT" = "true" ] || [ "$CHECK_MODE" = "true" ]; } && return 0
  echo ""
  echo -e "  ${BG_BLUE}${WHITE}  SWITCH TO BROWSER  ${NC}"
  echo -e "  ${BOLD}$*${NC}"
  pause
}


###############################################################################
# Showing the work
#
# Every request below is built ONCE into an argv array and a display string from
# the same values, then printed and executed. So the command on screen is
# provably the command that ran — not a prettified approximation of it. The
# response is printed verbatim underneath, because a demo that shows only status
# codes is asking the room to take our word for it.
###############################################################################
CURL_ARGS=()
CURL_LINES=()

json_str() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

build_llm_curl() {   # <key> <model> <prompt-or-RAW-body>
  local key=$1 model=$2 prompt=$3 body
  if [ "$model" = "RAW" ]; then body=$prompt
  else body=$(printf '{"model":"%s","messages":[{"role":"user","content":%s}]}' "$model" "$(json_str "$prompt")")
  fi
  CURL_ARGS=(-s -w '\n%{http_code}' --max-time 25 "${LLM}/v1/chat/completions"
             -H 'Content-Type: application/json')
  CURL_LINES=("curl ${LLM}/v1/chat/completions" "-H 'Content-Type: application/json'")
  if [ -n "$key" ]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${key}")
    CURL_LINES+=("-H 'Authorization: Bearer ${key}'")
  fi
  CURL_ARGS+=(-d "$body")
  CURL_LINES+=("-d '${body}'")
}

build_mcp_curl() {   # <sid> <json>
  local sid=$1 body=$2
  CURL_ARGS=(-s --max-time 30 "${MCP}/mcp"
             -H 'Content-Type: application/json'
             -H 'Accept: application/json, text/event-stream'
             -H "Mcp-Session-Id: ${sid}" -d "$body")
  CURL_LINES=("curl ${MCP}/mcp"
              "-H 'Content-Type: application/json'"
              "-H 'Accept: application/json, text/event-stream'"
              "-H \"Mcp-Session-Id: \$SID\""
              "-d '${body}'")
}

# Print the command across lines with continuations, wrapping any single line
# that is too wide to read from the back of a room.
print_curl() {
  { [ "$SILENT" = "true" ] || [ "$CHECK_MODE" = "true" ]; } && return 0
  local n=${#CURL_LINES[@]} i=0 line prefix cont
  while [ $i -lt $n ]; do
    line=${CURL_LINES[$i]}
    if [ $i -eq 0 ]; then prefix="\$ "; else prefix="    "; fi
    if [ $((i+1)) -lt $n ]; then cont=" \\"; else cont=""; fi
    # A long -d payload gets pretty-printed rather than truncated. Truncating it
    # would hide the very thing a scene exists to show — the tool result carrying
    # the tool result carrying customer data, for instance.
    if [ ${#line} -gt 120 ] && [ "${line:0:4}" = "-d '" ]; then
      echo -e "  ${YELLOW}${prefix}-d '${NC}"
      printf '%s' "${line:4:${#line}-5}" | python3 -c '
import sys,json
raw=sys.stdin.read()
try: print(json.dumps(json.loads(raw), indent=2))
except Exception: print(raw)
' 2>/dev/null | while IFS= read -r jl; do printf '      %b%s%b\n' "$YELLOW" "$jl" "$NC"; done
      echo -e "  ${YELLOW}    '${NC}${cont}"
    else
      echo -e "  ${YELLOW}${prefix}${line}${NC}${cont}"
    fi
    i=$((i+1))
  done
}

# Print a response verbatim, pretty-printed when it is JSON, capped by LINES so
# it never ends mid-token the way a byte cap does.
print_resp() {   # <body> [max-lines]
  { [ "$SILENT" = "true" ] || [ "$CHECK_MODE" = "true" ]; } && return 0
  local body=$1 max=${2:-14} total
  echo -e "  ${DIM}response:${NC}"
  local pretty
  pretty=$(printf '%s' "$body" | python3 -c '
import sys,json
raw=sys.stdin.read().strip()
try:
    print(json.dumps(json.loads(raw), indent=2))
except Exception:
    print(raw)
' 2>/dev/null)
  total=$(printf '%s\n' "$pretty" | wc -l | tr -d ' ')
  printf '%s\n' "$pretty" | head -n "$max" | sed 's/^/      /'
  if [ "$total" -gt "$max" ]; then
    echo -e "      ${DIM}… $((total - max)) more lines${NC}"
  fi
  echo ""
}

# demo_llm <label> <want-status> <why> <key> <model> <prompt|RAW body>
demo_llm() {
  local label=$1 want=$2 why=$3 key=$4 model=$5 prompt=$6
  build_llm_curl "$key" "$model" "$prompt"
  print_curl
  local out code body
  out=$(curl "${CURL_ARGS[@]}" 2>/dev/null)
  code=$(printf '%s' "$out" | tail -n1)
  body=$(printf '%s' "$out" | sed '$d')
  expect_why "$label" "$want" "$code" "$why"
  print_resp "$body"
}

# demo_mcp <label> <sid> <json> — prints command and response, returns body
DEMO_MCP_BODY=""
demo_mcp() {
  local label=$1 sid=$2 req=$3
  build_mcp_curl "$sid" "$req"
  print_curl
  local raw
  raw=$(curl "${CURL_ARGS[@]}" 2>/dev/null)
  if printf '%s' "$raw" | grep -q '^data: '; then
    DEMO_MCP_BODY=$(printf '%s' "$raw" | sed -n 's/^data: //p')
  else
    DEMO_MCP_BODY=$raw
  fi
  print_resp "$DEMO_MCP_BODY" 700
}

###############################################################################
# Gateway helpers
###############################################################################

# apply <act-file> — swap the live config and wait for the proxy to reload it.
# No restart: the proxy watches the file. That is the whole standalone story.
apply() {
  local f="${ACTS}/$1"
  [ "$CHECK_MODE" = "true" ] || echo -e "  ${YELLOW}\$ cp config/acts/$1 config/config.yaml${NC}"
  local before; before=$(effective_fingerprint)
  cp "$f" "$CFG"
  wait_changed "$before" || check_fail "config did not reload within 30s (see docker compose logs)"
  # The admin API reports the new config before the data plane serves it — the
  # same lag that makes toolMode need a restart. Without this settle, the FIRST
  # request of a scene is answered by the previous act's configuration, which on
  # stage looks like the feature you just enabled not working.
  sleep 3
}

# A fingerprint of the parts of the running config the demo actually asserts on.
# Polling this is the only honest way to know a reload landed: the file changing
# and the proxy having re-read it are different events.
effective_fingerprint() {
  curl -s --max-time 3 "${UI}/api/config/effective" 2>/dev/null | python3 -c '
import sys,json,hashlib
try:
    d=json.load(sys.stdin)
except Exception:
    print("none"); raise SystemExit
llm=d.get("llm") or {}
sub={
 "keys": bool((llm.get("policies") or {}).get("apiKey")),
 "models": sorted(m.get("name","") for m in (llm.get("models") or [])),
 "virtual": sorted(m.get("name","") for m in (llm.get("virtualModels") or [])),
 "mcp": (d.get("mcp") or {}).get("toolMode"),
 "attrs": (d.get("config") or {}).get("standardAttributes"),
}
print(hashlib.sha256(json.dumps(sub,sort_keys=True).encode()).hexdigest()[:16])
' 2>/dev/null || echo none
}

wait_changed() {
  local before=$1 i=0 now
  while [ $i -lt 30 ]; do
    now=$(effective_fingerprint)
    if [ -n "$now" ] && [ "$now" != "none" ] && [ "$now" != "$before" ]; then
      return 0
    fi
    i=$((i+1)); sleep 1
  done
  return 1
}

wait_reload() { sleep 2; }

# set_tool_mode <mode> — edit the ONE line that carries the token story, then
# wait until the running config actually reports it. Each MCP session picks up
# the mode in force when the session starts, so we must confirm before opening
# a new session or the "before" and "after" look identical.
# set_tool_mode <mode> <expected-tool-count>
#
# IMPORTANT, and contrary to the documentation: changing `toolMode` does NOT take
# effect on a hot reload in 2026.9.0. The admin API reports the new mode within a
# second, but the MCP listener keeps serving the old one indefinitely — measured
# at 30s with no change. Restarting the proxy applies it immediately.
#
# So this function restarts. Say what you are doing and why: everything
# else in this demo reloads live, and this one field does not yet.
set_tool_mode() {
  local mode=$1 want=$2 i=0 n
  if [ "$CHECK_MODE" != "true" ] && [ "$SILENT" != "true" ]; then
    echo -e "  ${YELLOW}\$ sed -i 's/^  toolMode: .*/  toolMode: ${mode}/' config/config.yaml${NC}"
    echo -e "  ${YELLOW}\$ docker compose restart agentgateway${NC}"
  fi
  sed -i '' -E "s/^  toolMode: .*/  toolMode: ${mode}/" "$CFG" 2>/dev/null \
    || sed -i -E "s/^  toolMode: .*/  toolMode: ${mode}/" "$CFG"
  (cd "$SCRIPT_DIR" && docker compose restart agentgateway >/dev/null 2>&1)
  while [ $i -lt 45 ]; do
    curl -s --max-time 2 "${UI}/api/config/effective" >/dev/null 2>&1 && break
    i=$((i+1)); sleep 1
  done
  sleep 2
  i=0
  while [ $i -lt 20 ]; do
    n=$(mcp_call "$(mcp_open)" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' 2>/dev/null | tool_count 2>/dev/null)
    [ "$n" = "$want" ] && return 0
    i=$((i+1)); sleep 1
  done
  return 1
}

# Poll until an unauthenticated request is actually refused. Same reason: adding
# the API key policy is reported before it is enforced.
wait_until_enforced() {
  local i=0
  while [ $i -lt 30 ]; do
    [ "$(llm_code "" chat-standard 'probe')" = "401" ] && return 0
    i=$((i+1)); sleep 1
  done
  return 1
}

llm_code() {  # llm_code <key> <model> <prompt>
  curl -s -o /dev/null -w '%{http_code}' --max-time 25 "${LLM}/v1/chat/completions" \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d "$(printf '{"model":"%s","messages":[{"role":"user","content":%s}]}' "$2" "$(printf '%s' "$3" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')")"
}

llm_body() {  # llm_body <key> <model> <prompt> — response body, truncated
  curl -s --max-time 25 "${LLM}/v1/chat/completions" \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d "$(printf '{"model":"%s","messages":[{"role":"user","content":%s}]}' "$2" "$(printf '%s' "$3" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')")"
}

# A request whose TOOL RESULT carries customer data — the agentic shape.
llm_toolout_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 25 "${LLM}/v1/chat/completions" \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d '{"model":"chat-standard","messages":[{"role":"user","content":"look up this record"},{"role":"assistant","tool_calls":[{"id":"c1","type":"function","function":{"name":"lookup_record","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c1","content":"record_id=ACCT-482913 email=jane.doe@example.com"}]}'
}

llm_who() {   # llm_who <key> <model> <prompt> — which upstream answered
  curl -s --max-time 25 "${LLM}/v1/chat/completions" \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d "$(printf '{"model":"%s","messages":[{"role":"user","content":%s}]}' "$2" "$(printf '%s' "$3" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')")" \
    | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); c=d["choices"][0]["message"]["content"]
    print(c.split("]")[0].strip("[") if c.startswith("[") else "?")
except Exception: print("error")'
}

mcp_sid() {
  curl -sD /tmp/agw-mcp-h -o /dev/null --max-time 15 "${MCP}/mcp" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"agw-demo","version":"1"}}}' >/dev/null
  awk -F': *' 'tolower($1)=="mcp-session-id"{gsub(/\r/,"",$2);print $2}' /tmp/agw-mcp-h
}

# mcp_call <sid> <json>
#
# Successful results come back SSE-framed ("data: {...}"), but JSON-RPC ERRORS
# come back as bare JSON with no framing. Filtering on "^data: " therefore threw
# away exactly the responses the authorization scene needs to prove. Handle both.
mcp_call() {
  local out
  out=$(curl -s --max-time 30 "${MCP}/mcp" -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" -H "Mcp-Session-Id: $1" \
        -d "$2")
  if printf '%s' "$out" | grep -q '^data: '; then
    printf '%s' "$out" | sed -n 's/^data: //p'
  else
    printf '%s' "$out"
  fi
}

mcp_open() {  # returns a session id with the handshake completed
  local sid; sid=$(mcp_sid)
  mcp_call "$sid" '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  printf '%s' "$sid"
}

tool_names() { python3 -c 'import sys,json
d=json.load(sys.stdin); print(",".join(t["name"] for t in d["result"]["tools"]))'; }

tool_count() { python3 -c 'import sys,json
d=json.load(sys.stdin); print(len(d["result"]["tools"]))'; }

# How much of the model context the tool list costs, in characters of JSON.
tool_weight() { python3 -c 'import sys,json
d=json.load(sys.stdin); print(len(json.dumps(d["result"]["tools"])))'; }


# --- Identity helpers --------------------------------------------------------
# Tokens are fetched from INSIDE the compose network, because the Keycloak issuer
# is `keycloak:18083` and that name does not resolve on the host. Doing it this
# way means the demo needs no /etc/hosts entry and no sudo. The one thing that
# does need it is the interactive browser login — see README.
KC_REALM_URL="http://keycloak:18083/realms/demo"

kc_token() {   # kc_token <username>
  docker compose exec -T mcp-records python3 -c "
import urllib.request, urllib.parse, json, sys
d=urllib.parse.urlencode({'grant_type':'password','client_id':'demo-cli',
                          'username':sys.argv[1],'password':'demo','scope':'openid'}).encode()
try:
    print(json.load(urllib.request.urlopen('${KC_REALM_URL}/protocol/openid-connect/token', d, timeout=12))['access_token'])
except Exception: print('')
" "$1" 2>/dev/null | tr -d '\r'
}

kc_agent_token() {
  docker compose exec -T mcp-records python3 -c "
import urllib.request, urllib.parse, json
d=urllib.parse.urlencode({'grant_type':'client_credentials','client_id':'demo-agent',
                          'client_secret':'demo-agent-secret','scope':'openid'}).encode()
try:
    print(json.load(urllib.request.urlopen('${KC_REALM_URL}/protocol/openid-connect/token', d, timeout=12))['access_token'])
except Exception: print('')
" 2>/dev/null | tr -d '\r'
}

# Exchange a user token plus an agent token for a delegated token, and print the
# the claims that matter. This is the RFC 8693 delegation flow.
sts_delegate() {   # sts_delegate <subject-token> <actor-token>
  docker compose exec -T mcp-records python3 -c "
import urllib.request, urllib.parse, json, base64, sys
JWT='urn:ietf:params:oauth:token-type:jwt'
d=urllib.parse.urlencode({'grant_type':'urn:ietf:params:oauth:grant-type:token-exchange',
  'subject_token':sys.argv[1],'subject_token_type':JWT,
  'actor_token':sys.argv[2],'actor_token_type':JWT}).encode()
try:
    t=json.load(urllib.request.urlopen('http://agentgateway:7777/oauth2/token', d, timeout=15))['access_token']
except Exception as e:
    print(json.dumps({'error':str(e)})); raise SystemExit
p=t.split('.')[1]; p+='='*((4-len(p)%4)%4)
c=json.loads(base64.urlsafe_b64decode(p))
print(json.dumps({k:c[k] for k in ('iss','sub','act','exp') if k in c}, indent=2))
" "$1" "$2" 2>/dev/null
}

###############################################################################
# Reset / preflight
###############################################################################
# Reset RESTARTS the proxy rather than just swapping the file, for two reasons
# learned the hard way:
#
#   1. A hot reload that REMOVES a policy does not tear the old one down. Going
#      from Act 2 (API keys required) back to Act 1 (no keys) leaves the key
#      policy enforcing, and every Act 1 request 401s. Adding policies reloads
#      live, which is what the demo actually shows; removing them does not.
#   2. Budgets accumulate in the SQLite database over a rolling window, so a
#      second run of --check starts with the checkout-api budget already spent
#      and returns 429 instead of 200.
#
# Restarting and clearing the budget rows makes the demo repeatable, which
# matters more than saving eight seconds.
reset_demo() {
  cp "${ACTS}/00-base.yaml" "$CFG"
  curl -s -X POST "${PRIMARY_CTL}/control/heal" >/dev/null 2>&1
  python3 - <<'EOF' 2>/dev/null || true
import sqlite3, os
p = os.path.join(os.path.dirname(os.path.abspath("demo.sh")), "data", "demo.db")
try:
    c = sqlite3.connect(p); c.execute("DELETE FROM budget_usage"); c.commit(); c.close()
except Exception:
    pass
EOF
  (cd "$SCRIPT_DIR" && docker compose restart agentgateway >/dev/null 2>&1)
  local i=0
  while [ $i -lt 45 ]; do
    curl -s --max-time 2 "${UI}/api/config/effective" >/dev/null 2>&1 && break
    i=$((i+1)); sleep 1
  done
  sleep 2
  [ "$CHECK_MODE" = "true" ] || echo -e "${DIM}Reset to the Act 0 configuration.${NC}"
}

preflight() {
  echo -e "${BOLD}Preflight check...${NC}"
  local ok=true

  local lic
  lic=$(curl -s --max-time 5 "${UI}/api/runtime" 2>/dev/null \
        | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d.get("license",{}).get("state","none"))
except Exception: print("none")')
  if [ "$lic" = "running" ]; then
    check_ok "Enterprise licence loaded (state=running)"
  elif [ "$lic" = "grace" ]; then
    check_ok "Licence in GRACE — renew before the call"
  else
    check_fail "No enterprise licence. Act 2's toolMode scene will silently do nothing,"
    check_fail "  because the OSS proxy always behaves as toolMode: standard."
    check_fail "  Put the key in .env as ENTERPRISE_AGENTGATEWAY_LICENSE_KEY, or in config/license.key."
    ok=false
  fi

  curl -s --max-time 3 "${UI}/api/config/effective" >/dev/null 2>&1 \
    && check_ok "Gateway admin reachable (${UI})" \
    || { check_fail "Gateway not reachable — run: docker compose up -d"; ok=false; }

  curl -s --max-time 3 "${PRIMARY_CTL}/health" >/dev/null 2>&1 \
    && check_ok "Upstreams up (primary/backup/local)" \
    || { check_fail "Mock upstreams not up — run: docker compose up -d"; ok=false; }

  local sid; sid=$(mcp_sid)
  [ -n "$sid" ] && check_ok "MCP listener answering (${MCP}/mcp)" \
    || { check_fail "MCP listener not answering"; ok=false; }

  # Identity is only needed from Act 3, so these warn rather than fail.
  if [ -n "$(kc_token dev-user)" ]; then
    check_ok "Keycloak realm 'demo' up, demo users present"
  else
    echo -e "  ${YELLOW}▸ Keycloak not answering — Act 3 identity scenes will fail.${NC}"
    echo -e "  ${YELLOW}  docker compose up -d keycloak && ./scripts/setup-keycloak.sh${NC}"
  fi
  if curl -s --max-time 4 http://localhost:7777/.well-known/openid-configuration >/dev/null 2>&1; then
    check_ok "STS answering (delegation scene)"
  else
    echo -e "  ${YELLOW}▸ STS not answering. Act 3's delegation scene will fail.${NC}"
    echo -e "  ${YELLOW}  Set AGW_BUNDLE_STS_ENABLED=true in .env, then: docker compose up -d agentgateway${NC}"
  fi

  if [ "$ok" = false ]; then
    echo -e "\n${RED}Fix the above, then re-run.  docker compose up -d${NC}"
    exit 1
  fi
  echo ""
}

###############################################################################
# Args
###############################################################################
START_ACT=1
END_ACT=3
while [ $# -gt 0 ]; do
  case "$1" in
    --reset) reset_demo; exit 0 ;;
    --check) CHECK_MODE=true; shift ;;
    --act)   START_ACT=${2:-1}; END_ACT=$START_ACT; shift 2 ;;
    [1-3])   START_ACT=$1; END_ACT=$1; shift ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done
silent_for() { if [ "$1" -lt "$START_ACT" ]; then SILENT=true; else SILENT=false; fi; }

reset_demo
preflight

###############################################################################
# ACT 1 — THE DEVELOPER PATH
###############################################################################
silent_for 1
if [ "$START_ACT" -le 1 ]; then
act 1 "The developer path"

scene "Put the coding agents behind the gateway"
narrate "Coding agents speak an OpenAI- or Anthropic-shaped API. Pointing one at"
narrate "the gateway is a base URL and a key. No plugin, no agent framework, and"
narrate "no change to how anybody works — which is the bar this has to clear."
apply 01-developer.yaml
show_config "virtualModels:" 22
callout "Those are names you own, not vendor SKUs. One line here moves every"
callout "caller of chat-standard to another model or another vendor."
pause

scene "A request through the gateway"
narrate "This is the whole integration. A base URL and a model name."
demo_llm "chat-standard answered" "200" "no key required yet" "" chat-standard 'Explain what this function does'
callout "Read the content field: it names the upstream that actually served it,"
callout "which is how the routing scenes below stay honest."
expect "served by" "primary-provider" "$(llm_who "" chat-standard 'hello')"
callout "Nothing about the developer's day changed. That is the point of Act 1."
pause

scene "Model steering — one config line, no application change"
narrate "Same endpoint, same client, a different model name."
demo_llm "chat-premium → the premium tier" "200" "note model=gpt-4o in the response" "" chat-premium 'draft a policy summary'
demo_llm "chat-local → an on-prem model" "200" "served by local-model" "" chat-local 'summarise this function'
expect "chat-local upstream" "local-model" "$(llm_who "" chat-local 'hello')"
callout "A self-hosted model is routed and governed exactly like a hosted one."
callout "If you have no GPUs yet, the point is that enabling them later is a"
callout "config change rather than a project."
pause

scene "A request carrying more than code"
narrate "Coding assistants were widely approved for completion. They are agentic"
narrate "now, which means they send whatever context a task pulls in — including"
narrate "tool results. The approval did not cover that."
narrate "This guard runs at the gateway, so it covers every client at once,"
narrate "without touching a single IDE."
show_config "    guardrails:" 18
demo_llm "ordinary code question" "200" "goes straight through" "" chat-standard 'refactor this function to use a switch'
demo_llm "same developer, customer data in the prompt" "400" "blocked" "" chat-standard 'why is the order for jane.doe@example.com failing'
callout "That rejection body is yours, not ours. Write it so a developer knows"
callout "what to do next instead of filing a ticket."
narrate "Now the agentic shape: the prompt is clean, but a TOOL RESULT carries a"
narrate "customer record back to the model."
demo_llm "PII arriving from tool output" "400" "caught on the way back" "" RAW '{"model":"chat-standard","messages":[{"role":"user","content":"look up this record"},{"role":"assistant","tool_calls":[{"id":"c1","type":"function","function":{"name":"lookup_record","arguments":"{}"}}]},{"role":"tool","tool_call_id":"c1","content":"record_id=ACCT-482913 email=jane.doe@example.com"}]}'
callout "This is the one that matters. A guard reads the prompt by default and"
callout "NOT tool results, so the agentic case — the one that actually changed —"
callout "is the case you have to opt into explicitly with scope."
pause

scene "Graceful degradation — and the honest caveat"
narrate "Failover is configured with priority groups. But routing.failover ALONE"
narrate "does nothing: you must also set health.eviction on the concrete models,"
narrate "or traffic keeps hitting the top priority group forever."
show_config "  - name: primary" 12
callout "Now take the primary provider down."
[ "$CHECK_MODE" = "true" ] || echo -e "  ${YELLOW}\$ curl -s -X POST ${PRIMARY_CTL}/control/fail${NC}"
FAILOUT=$(curl -s -X POST "${PRIMARY_CTL}/control/fail")
print_resp "$FAILOUT" 120
demo_llm "first request after the outage" "503" "this one trips the eviction" "" chat-resilient 'hello'
callout "Say this out loud: the request that TRIPS eviction still fails. Retries"
callout "cover it. Pretending otherwise is the kind of thing that surfaces in"
callout "week one of a POV."
expect "next request fails over" "backup-provider" "$(llm_who "" chat-resilient 'hello')"
expect "and stays there while primary is evicted" "backup-provider" "$(llm_who "" chat-resilient 'hello')"
curl -s -X POST "${PRIMARY_CTL}/control/heal" >/dev/null
callout "Primary restored. Eviction expires and traffic returns on its own."
pause
fi # end ACT 1

###############################################################################
# ACT 2 — THE ADMIN VIEW AND THE COST STORY
###############################################################################
silent_for 2
if [ "$START_ACT" -le 2 ]; then
act 2 "The admin view and the cost story"

scene "Keys issued per project, not per person"
narrate "A project's cost used to be people. It is now people plus tokens, and"
narrate "somebody has to be able to put the second number next to the first."
apply 02-cost.yaml
wait_until_enforced || check_fail "API key policy never began enforcing"
show_config "    apiKey:" 20
demo_llm "no key at all" "401" "strict mode" "" chat-standard 'summarise this changelog'
demo_llm "the checkout-api project key" "200" "attributed to the project" "$K_CHECKOUT" chat-standard 'summarise this changelog'
callout "Spend now carries the project name on every request, and the dashboard"
callout "also splits by user agent for free — one coding client versus another,"
callout "with no configuration at all."
pause

scene "The policy they already wrote, enforced"
narrate "allowedModels on a key stops a project reaching a tier it is not approved for."
demo_llm "analytics → chat-standard" "200" "on the allowlist" "$K_ANALYTICS" chat-standard 'rank these results'
demo_llm "analytics → chat-premium" "403" "not on the allowlist" "$K_ANALYTICS" chat-premium 'rank these results'
callout "That request never reached a provider. Nothing was sent, logged upstream, or billed."
pause

scene "The soft-limit nudge, then the hard stop"
narrate "A hard cap that stops work with no warning is a support ticket. The"
narrate "usual ask is a nudge first, then enforcement."
show_config "        budgets:" 16
narrate "Two budgets on one key. Audit records the overage and lets the request"
narrate "through; Block stops the next one."
narrate "Spending the checkout-api budget down..."
for i in $(seq 1 14); do llm_code "$K_CHECKOUT" chat-standard "burn budget $i" >/dev/null; done
callout "Be precise about what the nudge is: the gateway emits a log event, and"
callout "routing that to a human is your log pipeline's job, not an IDE toast."
callout "Budgets also charge AFTER the response, so a budget caps what a key can"
callout "START, not what it can spend."
pause

scene "The cost line, in dollars"
ui_moment "${UI}/ui/llm/analytics — Group by User, Measure = Cost, then the User agent split."
callout "That is the instrument. Not a discount — a number you can put in a"
callout "project's cost line next to the people."
pause

scene "The token story: one line of config"
narrate "An MCP server can expose dozens of tools, and every tool definition the"
narrate "gateway forwards is spent from the model's context before any work happens."
set_tool_mode standard 6 || check_fail "standard mode did not settle"
SID=$(mcp_open)
demo_mcp "tools/list" "$SID" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
STD_JSON=$DEMO_MCP_BODY
STD_N=$(printf '%s' "$STD_JSON" | tool_count); STD_W=$(printf '%s' "$STD_JSON" | tool_weight)
echo -e "  ${DIM}toolMode: standard${NC}"
expect "tools the client sees" "6" "$STD_N"
narrate "  tool definitions cost ${STD_W} characters of context"
callout "Now change ONE line. The proxy watches the file — no restart."
set_tool_mode code 1 || check_fail "toolMode code did not take effect — is the licence loaded?"
SID=$(mcp_open)
demo_mcp "tools/list" "$SID" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
CODE_JSON=$DEMO_MCP_BODY
CODE_N=$(printf '%s' "$CODE_JSON" | tool_count); CODE_W=$(printf '%s' "$CODE_JSON" | tool_weight)
echo -e "  ${DIM}toolMode: code${NC}"
expect "tools the client sees" "1" "$CODE_N"
expect "and it is" "run_code" "$(printf '%s' "$CODE_JSON" | tool_names)"
narrate "  tool definitions cost ${CODE_W} characters of context"
callout "This is an ENTERPRISE feature. The open source proxy always behaves as"
callout "though toolMode is standard — so on an unlicensed proxy this scene"
callout "silently does nothing."
pause

scene "And the chaining is where the tokens actually go"
narrate "One call, two different MCP servers, and only the composed result comes back."
show_send 'run_code: get_service_health("orders-api") then search_orders("returns")'
demo_mcp "run_code" "$SID" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"run_code","arguments":{"code":"const h = await platform_ops_get_service_health({service: \"orders-api\"}); const c = await records_search_orders({query: \"returns\"}); ({health: h, orders: c})"}}}'
RC=$DEMO_MCP_BODY
if printf '%s' "$RC" | grep -q '"success"'; then
  check_ok "run_code chained two federated servers in one round trip"
else
  check_fail "run_code did not return a success envelope"
fi
callout "Neither intermediate result entered the model's context. Frame the saving"
callout "honestly: RBC saw a large reduction on their tool set, the number that"
callout "matters is yours, and measuring it on your own tool set is the point"
callout "of an evaluation."
pause
fi # end ACT 2

###############################################################################
# ACT 3 — GOVERNANCE, IDENTITY, AUDIT
###############################################################################
silent_for 3
if [ "$START_ACT" -le 3 ]; then
act 3 "Governance, identity, audit"

scene "One governed door, and an inventory of what is behind it"
narrate "The usual questions: what are people plugging in, how do we see it,"
narrate "and is it safe. This act answers them with screens rather than claims."
apply 03-governance.yaml
set_tool_mode standard 4 || check_fail "governed tool list did not settle"
SID=$(mcp_open)
demo_mcp "tools/list through the governed door" "$SID" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
FED=$DEMO_MCP_BODY
narrate "Two MCP servers federated behind one endpoint, names prefixed by target:"
if [ "$CHECK_MODE" != "true" ] && [ "$SILENT" != "true" ]; then
  printf '%s' "$FED" | tool_names | tr ',' '\n' | sed 's/^/      /'
fi
callout "That is the inventory question answered with a screen, not a sentence."
pause

scene "Governed, not merely single"
show_config "    mcpAuthorization:" 4
narrate "Six tools exist upstream. Four are authorized. export_record_table is bulk"
narrate "bulk data egress and restart_service is disruptive, so neither is allowed."
expect "tools the client can see" "4" "$(printf '%s' "$FED" | tool_count)"
demo_mcp "calling a tool that is not authorized" "$SID" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"records_export_record_table","arguments":{"table":"customers"}}}'
DENIED=$DEMO_MCP_BODY
if printf '%s' "$DENIED" | grep -q 'Unknown tool'; then
  check_ok "calling export_record_table → Unknown tool"
else
  check_fail "export_record_table was not filtered"
fi
callout "Note what the client got back: not 403, but Unknown tool. An unauthorized"
callout "tool is filtered out of tools/list, so the agent never learns it exists"
callout "and never writes a plan that depends on it."
callout "Say this too: these are ALLOW rules on purpose. A deny rule that fails to"
callout "evaluate fails open — the schema says so — and that is not a thing you"
callout "want in front of an auditor."
pause

scene "The audit record"
narrate "An audit record for an agent is not \"a container started\". It is what"
narrate "the prompt was, what tools it reached, what it got back, and how it ended."
demo_mcp "an authorized tool call, for the log" "$SID" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"records_lookup_record","arguments":{"record_id":"ACCT-482913"}}}' 
if [ "$CHECK_MODE" = "true" ]; then
  TOOL_LOGS=$(docker compose logs agentgateway 2>/dev/null | grep -c 'gen_ai.tool.name' || true)
  if [ "${TOOL_LOGS:-0}" -gt 0 ]; then
    check_ok "MCP tool calls carry method, target and tool name in the log (${TOOL_LOGS} entries)"
  else
    check_fail "no MCP tool call found in the structured log"
  fi
else
  docker compose logs agentgateway 2>/dev/null | grep 'gen_ai.tool.name' | tail -2 | cut -c1-240 | sed 's/^/      /'
fi
narrate "Method, target, session and tool name are logged by default. Adding"
narrate "mcp.tool.arguments and mcp.tool.result to the access log gives you the"
narrate "rest of that record."
callout "Say the trade-off out loud: reading prompts and tool results means the"
callout "gateway inspects bodies. That is what makes the record possible."
ui_moment "${UI}/ui/llm/logs — the per-request view. Then Analytics for the cost side."
pause

scene "Where it ships to"
narrate "OTLP out to an OpenTelemetry collector, which is how it reaches an"
narrate "aggregator or a SIEM. Most are generic OTLP destinations rather than"
narrate "named integrations, which is worth knowing before you plan the work."
narrate "The collector config in otel/collector.yaml is the only thing that changes."
pause

scene "Who may look at the cost data"
narrate "The ECS guide is explicit that the admin address has no authentication"
narrate "and must not be published from a task. The cost dashboard lives on it."
narrate "So the production answer is to serve the UI on a gateway behind OIDC."
show_config "ui:" 14
[ "$CHECK_MODE" = "true" ] || echo -e "  ${YELLOW}\$ curl -i http://localhost:14001/ui/${NC}"
UI_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:14001/ui/)
UI_LOC=$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 10 http://localhost:14001/ui/)
expect_why "unauthenticated UI request" "302" "$UI_CODE" "redirected to the IdP"
if [ "$CHECK_MODE" != "true" ] && [ "$SILENT" != "true" ]; then
  echo -e "  ${DIM}location:${NC}"
  printf '%s' "$UI_LOC" | cut -c1-150 | sed 's/^/      /'; echo "..."
fi
callout "Authorization code flow with PKCE, against Keycloak standing in for Okta."
callout "The rule behind it is '\"ai-admins\" in jwt.groups' — swap the issuer for"
callout "the Okta one and that line does not change."
narrate "Meanwhile the raw admin port is still wide open, which is exactly why the"
narrate "docs tell you not to publish it:"
ADMIN_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:15000/ui/)
expect_why "the raw admin address" "200" "$ADMIN_CODE" "no auth — do not expose this on ECS"
pause

scene "Delegation — the agent and the human, separately auditable"
narrate "Agent identity and delegated user identity are usually the hard part."
narrate "An agent calling on someone's behalf should not present the user's own"
narrate "IdP token downstream, and should not disappear behind a shared robot"
narrate "account either. RFC 8693 delegation issues a token that names both."
SUBJ_TOK=$(kc_token dev-user)
ACTOR_TOK=$(kc_agent_token)
if [ -z "$SUBJ_TOK" ] || [ -z "$ACTOR_TOK" ]; then
  check_fail "could not get tokens from Keycloak — run ./scripts/setup-keycloak.sh"
else
  narrate "A user signs in; the agent has its own service identity."
  [ "$CHECK_MODE" = "true" ] || echo -e "  ${YELLOW}\$ POST http://localhost:7777/oauth2/token${NC}"
  [ "$CHECK_MODE" = "true" ] || echo -e "  ${YELLOW}    grant_type=urn:ietf:params:oauth:grant-type:token-exchange${NC}"
  [ "$CHECK_MODE" = "true" ] || echo -e "  ${YELLOW}    subject_token=<user>  actor_token=<agent>${NC}"
  DELEG=$(sts_delegate "$SUBJ_TOK" "$ACTOR_TOK")
  print_resp "$DELEG" 12
  if printf '%s' "$DELEG" | grep -q '"act"' && printf '%s' "$DELEG" | grep -q '"sub"'; then
    check_ok "issued token carries sub (the human) AND act (the agent)"
  else
    check_fail "delegated token missing sub or act"
  fi
  callout "sub is the user. act is the agent. A downstream service can audit the"
  callout "two separately instead of seeing one shared robot account."
  callout "And note WHO authorised it: the subject token carries a may_act claim"
  callout "from Keycloak. The IdP decides which agent may act for which human."
  callout "The gateway enforces that decision; it does not make it."
fi
pause

scene "Two things this did not do"
narrate "Everything above ran against the gateway just now. Two notes so nothing"
narrate "here is mistaken for more than it is:"
narrate "  · Act 1 proved the routing with curl rather than a live IDE. To point a"
narrate "    real coding agent at it, run ./scripts/client-setup.sh — it prints the"
narrate "    endpoint, proves it answers, and links the per-client recipe."
narrate "  · The UI redirect in Act 3 is real, but completing the browser login"
narrate "    needs one /etc/hosts line. See the README."
callout "The models here are local mocks so this runs with no cloud credentials."
callout "Point config/acts/*.yaml at your own providers and nothing else changes."
pause

fi # end ACT 3

###############################################################################
# Finale
###############################################################################
if [ "$CHECK_MODE" = "true" ]; then
  echo ""
  if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All assertions passed.${NC}"
  else
    echo -e "${RED}${BOLD}${FAILURES} assertion(s) failed — see above.${NC}"
  fi
  exit $([ "$FAILURES" -eq 0 ] && echo 0 || echo 1)
fi

echo ""
echo -e "${BG_BLUE}${WHITE}                                                                        ${NC}"
echo -e "${BG_BLUE}${WHITE}   One gateway, one config file, no Kubernetes                           ${NC}"
echo -e "${BG_BLUE}${WHITE}                                                                        ${NC}"
echo ""
echo -e "  ${BOLD}Developers${NC}   Claude Code and Copilot unchanged; steering, local models,"
echo -e "                and failover that actually fails over"
echo -e "  ${BOLD}Cost${NC}         Keys per project, dollars not guesses, warn-then-stop budgets"
echo -e "  ${BOLD}Tokens${NC}       toolMode code — a tool catalogue collapsed into one call"
echo -e "  ${BOLD}Governance${NC}   One federated door, a real inventory, and an audit record"
echo ""
echo -e "  ${DIM}Every state you saw came from config/config.yaml, which the proxy${NC}"
echo -e "  ${DIM}re-read on its own. That is the whole deployment.${NC}"
echo ""
echo -e "${BOLD}Smoke test:${NC}  ./demo.sh --check"
echo -e "${BOLD}Reset:${NC}       ./demo.sh --reset"
echo ""
