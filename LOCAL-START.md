# Clean start — bring the local infra up so the PR gate works

The PR-to-main gate runs on **this machine** (self-hosted runner) and its
acceptance tests hit the **live kind-preprod cluster**. So before you open (or
push to) a PR, start the pieces below **in order**. ~2-3 minutes total.

One-time setup (see [RUNNER.md](RUNNER.md)): one self-hosted runner registered
per service repo (name + label = repo name), branch protection requires
`preprod-gate / gate`.

After a reboot nothing comes up by itself: the podman machine does not autostart,
and the kind node containers have `restart=no` (they are **stopped**, not deleted).

## Order: podman → kind → runner

### 1. Start the podman machine

```powershell
podman machine start
podman machine list          # LAST UP should read "Currently running"
```

Also confirm **Podman Desktop → Settings → "Docker compatibility" is ON** — the
gate's component-test step (Testcontainers) talks to the Docker-compatible API.

### 2. Start the kind cluster node

```powershell
$env:KIND_EXPERIMENTAL_PROVIDER = "podman"
podman start preprod-control-plane     # the gate uses kind-preprod
# podman start prod-control-plane      # optional, only if you use prod too
kind get clusters                      # should list: preprod (prod)
```

Wait until the node is Ready (~30-60 s):

```powershell
kubectl --context kind-preprod get nodes   # STATUS = Ready
```

> If `kind get clusters` does **not** list `preprod`, the cluster was deleted
> (not just stopped). Recreate it and reload the images per
> [HANDOFF.md](HANDOFF.md), then redeploy (step 3).

### 3. (optional) Sanity-check / pre-warm the app stack

The gate redeploys the stack itself (`helm upgrade --install`), so this is
optional. To verify health up front, from the `shop-infra` folder:

```powershell
helm upgrade --install shop ./helm --kube-context kind-preprod -n shop --create-namespace -f ./helm/values.yaml -f ./helm/values-preprod.yaml --force-conflicts --timeout 6m
kubectl --context kind-preprod -n shop get pods    # all Running
```

Pods auto-restart when the node comes back; infra uses ephemeral storage, so data
resets — that is fine, the acceptance suite provisions its own data each run.

### 4. Start the shared self-hosted runner

There is ONE org-level runner in `C:\actions-runner` (name `shop-preprod-1`,
label `shop-preprod`); it serves every gated repo. If you installed it as a
Windows service it is already running — skip to the online check. To run it in the
foreground (keep its window open while you work):

```powershell
cd C:\actions-runner
.\run.cmd                              # waits at "Listening for Jobs"
```

Confirm the runner is up:

```powershell
# Local: the listener process should be running
Get-Process Runner.Listener -ErrorAction SilentlyContinue
# GitHub: org Settings -> Actions -> Runners -> shop-preprod-1 = Idle/Active
#   (it also shows on each repo's Runners page as "Shared with this repository").
#   Via API needs the admin:org scope: gh auth refresh -h github.com -s admin:org
#   gh api orgs/ai-bot-playground/actions/runners
```

## Now open / push a PR

Any PR (to any base branch — or a new push to an open PR) in a gated service
triggers `preprod-gate / gate` on the shared `shop-preprod` runner:
**component tests → build image → deploy to kind-preprod → acceptance**. Watch it:

```powershell
gh pr checks <PR-number> -R ai-bot-playground/<service>
```

## Pre-flight checklist (before opening a PR)

- [ ] podman machine = "Currently running" (Docker compatibility ON)
- [ ] `kubectl --context kind-preprod get nodes` → Ready
- [ ] shared `shop-preprod` runner = online (`Get-Process Runner.Listener`; org Runners page)

## UI services on localhost (port-forward)

Three services are browsed via localhost and are **not** reachable through the
gateway — open separate port-forwards for each:

| Service | Localhost URL | Notes |
|---------|--------------|-------|
| shop-ui | http://localhost:3001 | In-cluster; needs port-forward |
| shop-token-metrics | http://localhost:8088 | In-cluster; needs port-forward |
| shop-qa-ui | http://localhost:8501 | NOT in the cluster — runs locally |

Quick start (forwards both in-cluster services in one terminal):

```powershell
.\port-forward-ui.ps1
```

Or manually:

```powershell
kubectl --context kind-preprod -n shop port-forward svc/shop-ui 3001:80
kubectl --context kind-preprod -n shop port-forward svc/shop-token-metrics 8088:8080
```

For **shop-qa-ui** start it locally (it connects to the cluster via the above forwards):

```powershell
cd ..\shop-qa-ui
.\.venv\Scripts\activate
$env:TOKEN_METRICS_URL = "http://localhost:8088"
streamlit run app.py --server.port 8501
```

## Token-usage dashboard (Grafana)

The chart deploys with the stack (`observability.enabled=true`): **shop-token-metrics**
collects LLM token usage (Micrometer → `/actuator/prometheus`), **Prometheus** scrapes it,
**Grafana** charts it. To view it:

```powershell
kubectl --context kind-preprod -n shop port-forward svc/grafana 3000:3000
# open http://localhost:3000  ->  dashboard "LLM Token Usage" (anonymous, no login)
```

Point the QA tool at the collector so calls are recorded (in `shop-qa-ui/.env`):

```powershell
kubectl --context kind-preprod -n shop port-forward svc/shop-token-metrics 8088:8080
# then in shop-qa-ui/.env:  TOKEN_METRICS_URL=http://localhost:8088
```

Disable the whole observability stack with `--set observability.enabled=false`.

## Clean shutdown

```powershell
# stop the runner: Ctrl+C in its window (or stop the service)
podman machine stop          # also stops the kind node containers
```

Nothing else to tear down: the kind node and its pods come back on the next
start, and the gate redeploys the (ephemeral) app stack.
