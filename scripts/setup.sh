#!/usr/bin/env bash
#
# First-run setup. Safe to re-run.
#
#   ./scripts/setup.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

# 1. .env
if [ ! -f .env ]; then
  cp .env.example .env
  SECRET=$(openssl rand -hex 32)
  # portable in-place edit
  sed -i.bak "s/^OIDC_COOKIE_SECRET=.*/OIDC_COOKIE_SECRET=${SECRET}/" .env && rm -f .env.bak
  echo -e "${GREEN}✓${NC} created .env with a generated OIDC_COOKIE_SECRET"
  echo -e "${YELLOW}▸${NC} now put your licence key in .env as ENTERPRISE_AGENTGATEWAY_LICENSE_KEY"
else
  echo -e "${GREEN}✓${NC} .env already exists, leaving it alone"
fi

# 2. Licence key file, if the env var is set
set +u; . ./.env 2>/dev/null || true; set -u
if [ -n "${ENTERPRISE_AGENTGATEWAY_LICENSE_KEY:-}" ]; then
  printf '%s' "$ENTERPRISE_AGENTGATEWAY_LICENSE_KEY" > config/license.key
  chmod 600 config/license.key
  echo -e "${GREEN}✓${NC} wrote config/license.key from .env"
else
  echo -e "${RED}✗${NC} no licence key in .env — the proxy will not start."
  echo -e "  Put it in .env, then re-run this script."
fi

# 3. STS signing key. Owner 65532 so the STS, which runs as that uid inside the
#    container, can read it without a permission error.
if [ ! -f config/sts-jwt.pem ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out config/sts-jwt.pem 2>/dev/null
  chmod 600 config/sts-jwt.pem
  echo -e "${GREEN}✓${NC} generated config/sts-jwt.pem"
else
  echo -e "${GREEN}✓${NC} config/sts-jwt.pem already exists"
fi

# 4. Seed the live config. This file is gitignored because the demo rewrites it
#    between acts, so a fresh clone has nothing for the proxy to read at startup.
if [ ! -f config/config.yaml ]; then
  cp config/acts/00-base.yaml config/config.yaml
  echo -e "${GREEN}\u2713${NC} seeded config/config.yaml from Act 0"
else
  echo -e "${GREEN}\u2713${NC} config/config.yaml already exists"
fi

mkdir -p data
echo ""
echo -e "${BOLD}Next:${NC}"
echo "  docker compose up -d"
echo "  ./scripts/setup-keycloak.sh     # once Keycloak is up"
echo "  ./demo.sh --check"
