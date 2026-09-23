#!/usr/bin/env bash
#
# One-time Keycloak wiring that the realm import cannot do on its own.
#
# RFC 8693 delegation requires the SUBJECT token to carry a `may_act` claim
# naming the party allowed to act for that user. That is the important part of
# the story and worth saying out loud on the call: the identity provider decides
# which agent may act for which human. The gateway enforces that decision; it
# does not make it.
#
# `may_act` identifies the actor by its subject, and a Keycloak service account's
# subject is a UUID minted at import time. So it cannot be written into the realm
# JSON — it has to be looked up and wired afterwards, which is what this does.
#
# Safe to re-run: it deletes any mapper of the same name before adding it.
#
#   ./scripts/setup-keycloak.sh

set -euo pipefail

KC_CONTAINER=${KC_CONTAINER:-mcp-records}   # any container on the network with python
KC_URL=${KC_URL:-http://keycloak:18083}
REALM=${REALM:-demo}
ADMIN_USER=${ADMIN_USER:-admin}
ADMIN_PASS=${ADMIN_PASS:-admin}
AGENT_CLIENT=${AGENT_CLIENT:-demo-agent}
SUBJECT_CLIENT=${SUBJECT_CLIENT:-demo-cli}
MAPPER_NAME=${MAPPER_NAME:-may-act-demo-agent}

cd "$(dirname "${BASH_SOURCE[0]}")/.."

docker compose exec -T "${KC_CONTAINER}" python3 - "$KC_URL" "$REALM" "$ADMIN_USER" "$ADMIN_PASS" \
  "$AGENT_CLIENT" "$SUBJECT_CLIENT" "$MAPPER_NAME" <<'PY'
import json, sys, urllib.parse, urllib.request

KC, REALM, AU, AP, AGENT, SUBJ, MAPPER = sys.argv[1:8]

def req(method, path, token=None, body=None):
    url = f"{KC}{path}"
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    r = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=15) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path} -> {e.code}: {e.read().decode()[:300]}")

# 1. Admin token
tok_req = urllib.request.Request(
    f"{KC}/realms/master/protocol/openid-connect/token",
    urllib.parse.urlencode({
        "grant_type": "password", "client_id": "admin-cli",
        "username": AU, "password": AP,
    }).encode())
with urllib.request.urlopen(tok_req, timeout=15) as r:
    admin = json.load(r)["access_token"]

# 2. The agent's service-account subject, which is the value may_act must carry
agent_clients = req("GET", f"/admin/realms/{REALM}/clients?clientId={AGENT}", admin)
if not agent_clients:
    raise SystemExit(f"client {AGENT} not found in realm {REALM}")
agent_id = agent_clients[0]["id"]
sa_user = req("GET", f"/admin/realms/{REALM}/clients/{agent_id}/service-account-user", admin)
agent_sub = sa_user["id"]

# 2b. Ensure the `basic` client scope is attached.
#
# Naming defaultClientScopes in a realm import REPLACES Keycloak's default set,
# and `basic` is the scope that carries `sub`. Without it the subject token has
# no subject, so the exchanged token has nothing to put in `sub` and delegation
# records the agent but not the human — which defeats the point.
all_scopes = {s["name"]: s["id"] for s in req("GET", f"/admin/realms/{REALM}/client-scopes", admin)}
basic_id = all_scopes.get("basic")
for client_name in (SUBJ, AGENT):
    cl = req("GET", f"/admin/realms/{REALM}/clients?clientId={client_name}", admin)
    if not cl or not basic_id:
        continue
    cid = cl[0]["id"]
    attached = {s["name"] for s in req("GET", f"/admin/realms/{REALM}/clients/{cid}/default-client-scopes", admin) or []}
    if "basic" not in attached:
        req("PUT", f"/admin/realms/{REALM}/clients/{cid}/default-client-scopes/{basic_id}", admin)
        print(f"attached `basic` scope to {client_name}")

# 3. Put a may_act claim on the token the SUBJECT client issues
subj_clients = req("GET", f"/admin/realms/{REALM}/clients?clientId={SUBJ}", admin)
if not subj_clients:
    raise SystemExit(f"client {SUBJ} not found in realm {REALM}")
subj_id = subj_clients[0]["id"]

for m in req("GET", f"/admin/realms/{REALM}/clients/{subj_id}/protocol-mappers/models", admin) or []:
    if m.get("name") == MAPPER:
        req("DELETE", f"/admin/realms/{REALM}/clients/{subj_id}/protocol-mappers/models/{m['id']}", admin)

req("POST", f"/admin/realms/{REALM}/clients/{subj_id}/protocol-mappers/models", admin, {
    "name": MAPPER,
    "protocol": "openid-connect",
    "protocolMapper": "oidc-hardcoded-claim-mapper",
    "config": {
        "claim.name": "may_act",
        "claim.value": json.dumps({"sub": agent_sub}),
        "jsonType.label": "JSON",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "false",
    },
})

print(f"may_act wired: {SUBJ} tokens now authorize actor sub={agent_sub} ({AGENT})")
PY
