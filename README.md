# agentgateway standalone demo

> 📖 **Read the write-up:** [agentgateway Standalone: Guardrails, Budgets, Tool Governance](https://webofmike.com/agentgateway-standalone-demo/)

A three-act walkthrough of **Solo Enterprise for agentgateway** running as the
standalone binary — one configuration file, no Kubernetes, no cloud credentials
required.

It is built to be run, not watched. Every request prints the exact command and
its real response, and a single `--check` run asserts every claim the demo makes.

```bash
git clone <this repo> && cd agentgateway-standalone-demo
./scripts/setup.sh              # .env, licence key file, STS signing key
docker compose up -d
./scripts/setup-keycloak.sh     # once, after Keycloak is up
./demo.sh --check               # non-interactive: asserts everything
./demo.sh                       # interactive walkthrough
```

| | |
|---|---|
| `./demo.sh` | Full interactive walkthrough, Enter to advance |
| `./demo.sh --act 2` | Reset, fast-forward earlier acts silently, play act 2 |
| `./demo.sh --check` | Non-interactive smoke test of every assertion |
| `./demo.sh --reset` | Back to the Act 0 configuration |

If `--check` says **All assertions passed**, the demo will work.

---

## What it shows

### Act 1 — The developer path

Coding agents through the gateway, and the answer to "does this slow my
engineers down?" — a base URL and a key, no plugin, no agent framework.

Then **model steering**: names you control rather than vendor SKUs, so one line
of config moves every caller to a different model or a different vendor.
Weighted routing, a self-hosted model route, and failover with health eviction
configured properly.

Then the part that matters most. A guardrail that catches sensitive data
**arriving in a tool result**, not just in a prompt. Coding assistants were
widely approved for completion and are agentic now, which means they send
whatever context a task pulls in. A guard reads the prompt by default and *not*
tool output, so the case that actually changed is the one you have to opt into.

### Act 2 — The admin view and the cost story

Virtual keys issued per **project** rather than per person, so spend rolls up
the way a platform team reports it. The cost dashboard also splits by user agent
with no configuration, separating one coding client from another.

Model allowlists per key. Budgets that **warn and then stop** — an `Audit`
budget logs the overage and lets the request through, a `Block` budget stops the
next one. Budgets are available in dollars as well as tokens.

Then `toolMode: code`, which replaces a tool catalogue with a single `run_code`
tool. The demo shows a six-tool federated catalogue collapsing to one, then a
script chaining calls across two different MCP servers where only the composed
result returns to the model.

### Act 3 — Governance, identity, audit

Two MCP servers federated behind one endpoint, with a real inventory of what is
reachable. `mcpAuthorization` written as **allow** rules — a deny rule that
fails to evaluate fails open — so an unauthorized tool returns `Unknown tool`
rather than `403`: it is filtered out of `tools/list` and the agent never learns
it exists.

The audit record: method, target, session and tool name logged by default, with
tool arguments and results available as access-log fields.

The admin UI served on a gateway behind OIDC, because the admin address has no
authentication and the cost dashboard lives on it.

And **RFC 8693 delegation**: an agent acting for a user gets a token carrying
`sub` (the human) and `act` (the agent), so a downstream service can audit the
two separately instead of seeing one shared robot account.

---

## What runs

| Service | Why it is here |
|---|---|
| `agentgateway` | The enterprise bundle image. Reads `config/config.yaml`, which the demo rewrites between acts. |
| `upstream-primary` / `upstream-backup` / `upstream-local` | Small OpenAI-compatible mocks standing in for a primary provider, a backup, and a self-hosted model. They make the demo runnable with no cloud credentials and make failover deterministic — `POST /control/fail` arms an outage. |
| `mcp-records` / `mcp-platform-ops` | Two MCP servers, so Act 3 federates rather than proxying one thing. `records` returns synthetic PII and carries a tool worth denying. |
| `keycloak` | Stands in for your OIDC provider. Swap the issuer and JWKS URL and the policies are unchanged. |
| `otel-collector` | OTLP destination standing in for an aggregator or SIEM. |

All data in this repo is invented. No real person, record or organisation is
represented.

**To run against real providers**, change `provider` and `baseUrl` in
`config/acts/*.yaml`. Nothing else moves.

---

## How the acts work

Each act is a complete `config.yaml`. The demo copies one over
`config/config.yaml` and the proxy re-reads it — so what is on screen is what is
running, and you can read the whole configuration for any act in one file.

```
config/acts/00-base.yaml        gateway only: no identity, budgets, or guardrails
config/acts/01-developer.yaml   + models, virtual models, failover, guardrails
config/acts/02-cost.yaml        + virtual keys, allowlists, budgets, toolMode
config/acts/03-governance.yaml  + tool authorization, UI OIDC, delegation
```

The acts are strictly **additive**, and `--reset` restarts the proxy rather than
swapping a file back, which keeps repeated runs honest.

---

## Requirements

- Docker with Compose
- A Solo Enterprise for agentgateway licence key. Without one the proxy runs as
  open source: `toolMode` silently behaves as `standard` and the security token
  service is unavailable. `--check` tells you loudly.
- `python3`, `curl`, and `openssl` on the host (all standard on macOS and Linux)

### Ports

4000 LLM · 3000 MCP · 15000 admin UI (localhost only) · 14001 UI gateway ·
18080–18082 mock upstreams · 18083 Keycloak · 7777 STS · 4317 OTLP

### One optional step

Act 3 shows the admin UI redirecting to the identity provider, which needs no
setup. Actually *completing* that browser login does, because the issuer is
`keycloak:18083` and a browser on the host cannot resolve it:

```bash
echo "127.0.0.1 keycloak" | sudo tee -a /etc/hosts
```

Everything else fetches tokens from inside the compose network, so this is the
only step that wants `sudo`, and skipping it costs you one click.

### Cost figures

The cost dashboard prices requests from a model catalogue. Open
**LLM → Costs** in the UI at <http://localhost:15000/ui/llm/costs> and press
**Refresh base costs** once; the dashboard then shows realized dollars at
<http://localhost:15000/ui/llm/analytics>. Without a catalogue you still get
tokens and call counts, but cost reads zero.

---

## Pointing a real coding agent at it

```bash
./scripts/client-setup.sh
```

Prints the endpoint and a key, sends a real request to prove it answers, and
points at the gateway's own **Client Setup** page, which generates the per-client
recipe from the models and keys you actually have configured.

Act 1 proves the routing with `curl`, so wiring a live client is a bonus rather
than a dependency.

---

## Licence

The demo scaffolding in this repository is provided as-is for evaluation.
Solo Enterprise for agentgateway is commercial software and requires a licence
key, which is not included here.
