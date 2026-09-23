#!/usr/bin/env bash
#
# Point real coding agents at the gateway.
#
# Everything this prints has been checked against the running gateway rather than
# copied from a doc page: the script sends an actual request before it tells you
# the endpoint works.
#
# For the per-client recipe (the exact environment variables or settings keys a
# given client wants), use the gateway's own Client Setup page, which generates
# it from the models and keys you actually have configured:
#
#     http://localhost:15000/ui/llm/client-setup
#
# That page is the source of truth and it changes with the product. This script
# deliberately does not hardcode a second copy of it.
#
#   ./scripts/client-setup.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

LLM="http://localhost:4000"
UI="http://localhost:15000"
BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

KEY=${1:-sk-demo-platform-eng-5a1f77}

echo ""
echo -e "${BOLD}Gateway endpoint${NC}"
echo -e "  base URL   ${YELLOW}${LLM}/v1${NC}"
echo -e "  API key    ${YELLOW}${KEY}${NC}"
echo -e "  models     ${YELLOW}chat-standard  chat-premium  chat-resilient  chat-blend  chat-local${NC}"
echo ""

echo -e "${BOLD}Checking it actually answers...${NC}"
CODE=$(curl -s -o /tmp/agw-client-check -w '%{http_code}' --max-time 20 \
  "${LLM}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${KEY}" \
  -d '{"model":"chat-standard","messages":[{"role":"user","content":"reply with OK"}]}')

if [ "$CODE" = "200" ]; then
  echo -e "  ${GREEN}✓ ${LLM}/v1/chat/completions returned 200 with this key${NC}"
elif [ "$CODE" = "401" ]; then
  echo -e "  ${RED}✗ 401 — the gateway is in strict key mode and this key was not accepted.${NC}"
  echo -e "  ${DIM}  Pass a valid key: ./scripts/client-setup.sh sk-demo-...${NC}"
  echo -e "  ${DIM}  Keys live in config/acts/02-cost.yaml under llm.policies.apiKey.keys${NC}"
elif [ "$CODE" = "000" ]; then
  echo -e "  ${RED}✗ no answer on ${LLM} — is the stack up?  docker compose up -d${NC}"
else
  echo -e "  ${RED}✗ HTTP ${CODE}${NC}"
  head -c 200 /tmp/agw-client-check 2>/dev/null | sed 's/^/      /'
  echo ""
fi
rm -f /tmp/agw-client-check
echo ""

echo -e "${BOLD}Per-client settings${NC}"
echo -e "  Open ${YELLOW}${UI}/ui/llm/client-setup${NC}"
echo -e "  ${DIM}Pick a model and a key, choose the client from the Integration${NC}"
echo -e "  ${DIM}dropdown, and copy the generated recipe. It emits only the values${NC}"
echo -e "  ${DIM}that each client supports, which is why this script does not try${NC}"
echo -e "  ${DIM}to reproduce them.${NC}"
echo ""

echo -e "${BOLD}Two things to know before you wire Copilot${NC}"
echo -e "  ${YELLOW}1.${NC} Some coding clients require a ${BOLD}business or enterprise${NC} plan before"
echo -e "     they will honour a custom endpoint. Check your licence tier first."
echo -e "  ${YELLOW}2.${NC} The guardrail in Act 1 rejects customer data in prompts AND in tool"
echo -e "     results. That is deliberate, and it will reject real traffic that"
echo -e "     carries those identifiers. Point a scratch project at it first."
echo ""

echo -e "${DIM}Act 1 proves the routing with curl, so wiring a real client is a bonus${NC}"
echo -e "${DIM}rather than a dependency. If a laptop misbehaves, the demo still runs.${NC}"
echo ""
