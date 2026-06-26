# Clean start — bring the local infra up so the PR gate works

The PR-to-main gate runs on **this machine** (self-hosted runner) and its
acceptance tests hit the **live kind-preprod cluster**. So before you open (or
push to) a PR, start the pieces below **in order**. ~2-3 minutes total.

One-time setup (already done — see [RUNNER.md](RUNNER.md)): runner registered,
runner group allows public repos, branch protection requires `preprod-gate / gate`.

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

### 4. Start the self-hosted runner

Foreground (keep the window open while you work):

```powershell
cd C:\actions-runner
.\run.cmd                              # waits at "Listening for Jobs"
```

(If you later install it as a Windows service it is already running — skip this.)

Confirm it is online on GitHub:

```powershell
gh api orgs/ai-bot-playground/actions/runners | ConvertFrom-Json |
  Select-Object -ExpandProperty runners |
  ForEach-Object { "$($_.name): $($_.status)" }     # shop-preprod-1: online
```

## Now open / push a PR to main

Any PR to `main` (or a new push to an open PR) in a gated service triggers
`preprod-gate / gate` on your runner:
**component tests → build image → deploy to kind-preprod → acceptance**. Watch it:

```powershell
gh pr checks <PR-number> -R ai-bot-playground/<service>
```

## Pre-flight checklist (before opening a PR)

- [ ] podman machine = "Currently running" (Docker compatibility ON)
- [ ] `kubectl --context kind-preprod get nodes` → Ready
- [ ] runner = online (`gh api .../runners`)

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
