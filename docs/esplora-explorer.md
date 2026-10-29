# Esplora explorer: a public UI through Workers VPC

Design for review, 2026-10-29. Nothing below is built yet.

Goal: the Esplora UI for the regtest chain in `gitops/workloads/esplora`, reachable from the internet
at a fixed `*.workers.dev` address, served by a Flux-managed tenant app. No domain, no load balancer,
no public IP, no inbound firewall rule. A practice exposure: it may stay open for a while.

## Path of a request

```
browser
  │ https://<worker>.<account subdomain>.workers.dev/regtest/...
  ▼
Cloudflare Worker (a few lines: forward the request to the VPC Service binding)
  │ Workers VPC Service: tunnel + host + port
  ▼
Cloudflare Tunnel (named, remotely managed, no public hostname)
  │ cloudflared dials out from the cluster on TCP 7844
  ▼
cloudflared            namespace cloudflared        platform, restricted
  │ HTTP :8080
  ▼
explorer (nginx)       namespace explorer-dev-app   tenant, restricted
  │ /regtest/          static files
  │ /regtest/api/  →   proxy
  ▼
esplora (nginx → electrs → bitcoind)   namespace esplora   chain workload, baseline
```

One origin for the browser: the prebuilt UI asks for `/regtest/api` (relative, set at build time),
and the explorer's nginx forwards that path to the backend.

## Components

| Component | Where it lives | Owner | Notes |
|---|---|---|---|
| Egress TCP 7844 | `envs/nonprod/main.tf`, `egress_tcp_ports` | Terraform (CI apply) | cloudflared reaches Cloudflare on 7844; today only 443 is open |
| `cloudflared` | `gitops/infrastructure/` (new namespace `cloudflared`) | Flux, platform | `tunnel run`, token from a Secret; non-root, `restricted` |
| Tunnel token | Secret Manager → External Secrets → Secret `cloudflared-token` | platform | same pattern as the Grafana password; never in git |
| `explorer` tenant | `gitops/apps/base/explorer`, `apps/nonprod/explorer-dev`, one block in `clusters/nonprod/tenants.yaml` | Flux, tenant | the usual fence: `restricted`, quota, default-deny ingress |
| Static UI | copied at start from the pinned Esplora image | — | see "No image build" |
| Network openings | `explorer-dev-app`: from `cloudflared` to :8080. `esplora`: from `explorer-dev-app` to :80 | tenant / platform | everything else stays denied |
| Tunnel, VPC Service, Worker | Cloudflare account | by hand (dashboard and `wrangler`) | outside Flux; could move to Terraform later |

## No image build

The public Esplora image already contains the built UI for every flavor under
`/srv/explorer/static/<flavor>/`. `bitcoin-regtest` is the build without the Blockstream flavor:
`<base href="/regtest/">`, API at `/regtest/api`. Files are owned by root, mode 644/755, so a
non-root process can read them.

So the explorer pod has:

- an **initContainer** from the same pinned Esplora image, running as UID 65532, that copies
  `/srv/explorer/static/bitcoin-regtest/.` into an `emptyDir`;
- **nginx-unprivileged** on :8080 serving that `emptyDir` under `/regtest/` with
  `try_files $uri /regtest/index.html`, proxying `/regtest/api/` to
  `http://esplora.esplora.svc.cluster.local/regtest/api/` for GET and HEAD only, and redirecting
  `/` to `/regtest/`.

No registry, no CI job, no node pull permissions. The cost is pulling a ~430 MB image for a copy;
it is already cached on the node that runs the backend.

## Order of work

1. Terraform: add 7844 to `egress_tcp_ports`. Plan in CI, apply by hand (Run workflow on `main`).
2. Cloudflare dashboard (by hand): create a named tunnel, keep its token. No public hostname.
3. Secret Manager (by hand): store the token. Add the ExternalSecret next to the Grafana one.
4. Git: `cloudflared` in `infrastructure/`; the `explorer` tenant; the two NetworkPolicy openings.
   Push; Flux applies. Check `cloudflared` shows the tunnel healthy in the dashboard.
5. Cloudflare (by hand): a VPC Service on that tunnel, host
   `explorer.explorer-dev-app.svc.cluster.local`, port 8080.
6. Worker (by hand, `wrangler deploy`): a `vpc_services` binding to that service, `fetch` forwards
   the request. Enable its `workers.dev` route.
7. Check: `/regtest/` loads, a block page loads, `/regtest/api/blocks/tip/height` answers.

## Not confirmed yet

- Workers VPC is in **beta** ("features and APIs may change"); free on all plans during the beta,
  pricing after it is not published.
- The docs do not say outright that a Worker served on `workers.dev` may use a VPC Service binding.
  Bindings belong to the Worker, not its route, so it should; step 6 proves it either way.
- Whether a VPC Service host may be a cluster DNS name, resolved by `cloudflared`, or must be an
  IP. If an IP, use the explorer Service's ClusterIP.
- Request size and timeout limits through Workers VPC are not documented.
- The nginx rate limits in the backend key on `X-Forwarded-For`; whether the Worker path sets it
  decides whether those limits apply.

## Exposure and teardown

The UI and the read API of a regtest chain are public. Nothing else is: no Electrum port, no
metrics, and no write path (the explorer proxies GET and HEAD only, so `POST /tx` stops there). To close it: disable the Worker's
`workers.dev` route (instant), then remove the tenant block, `cloudflared` and port 7844 in git.
