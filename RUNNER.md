# Self-hosted runner + preprod merge gate

How a PR into `main` is gated by a full end-to-end run on the local
`kind-preprod` cluster, and what you must install once.

## What you install (once) — the only manual step

A **GitHub Actions self-hosted runner**, registered at the **organization**
level (`ai-bot-playground`) so every repo can use it, running **as your own user**
on this machine (so it shares your kubeconfig + podman machine).

1. GitHub → org `ai-bot-playground` → **Settings → Actions → Runners → New runner**
   → *New self-hosted runner* → Windows / x64. Copy the `--url` and `--token`
   from that page (the token is short-lived).
2. In a normal user PowerShell:
   ```powershell
   mkdir C:\actions-runner; cd C:\actions-runner
   # download URL is shown on the same GitHub page (actions-runner-win-x64-*.zip)
   Invoke-WebRequest -Uri <RUNNER_ZIP_URL> -OutFile runner.zip
   Expand-Archive runner.zip -DestinationPath .
   .\config.cmd --url https://github.com/ai-bot-playground --token <TOKEN> `
     --labels shop-preprod --name shop-preprod-1 --unattended
   ```
   `self-hosted` and `Windows`/`X64` labels are added automatically; we add
   `shop-preprod` so the gate can target this machine specifically.
3. Run it (foreground for the first test, then install as a service):
   ```powershell
   .\run.cmd                 # foreground
   # or, to persist across reboots (run elevated once):
   .\svc.cmd install; .\svc.cmd start
   ```
   > If you install it as a **service**, make sure the service account is **your
   > user** (not LocalSystem) — otherwise it won't see `~/.kube/config`, the
   > `kind-preprod` context or the podman machine.

### Runner prerequisites (already true on this machine)

`podman`, `kind`, `kubectl`, `helm`, `git`, `curl` and **Java 25** on the runner
user's PATH, the **podman machine running**, and the **`kind-preprod` cluster up
with the baseline stack deployed** (see `HANDOFF.md` runbook). The gate
re-applies the chart (`helm upgrade --install`, idempotent) but relies on the
baseline `:0.0.1` images of the *other* services already being loaded in the node.

## How the gate fires when you open a PR

Files involved:
- `shop-<service>/.github/workflows/pr-to-main.yml` — tiny trigger, one per
  application service (gateway, catalog, inventory, order, payment, notification).
- `shop-acceptance-tests/.github/workflows/gate.yml` — the reusable gate it calls.

Step by step, for e.g. a PR `shop-order: develop_v_0.0.1 → main`:

1. **Trigger.** GitHub reads `pr-to-main.yml` from the PR head branch and sees
   `on: pull_request: branches: [main]` → a check run **preprod-gate / gate**
   appears on the PR and is queued onto a `[self-hosted, shop-preprod]` runner.
2. **Serialize.** `concurrency: preprod-gate` ensures only one gate touches the
   shared preprod cluster at a time; others queue.
3. **Checkout.** The runner checks out three repos side by side: the PR candidate
   (`shop-order` at the merge result), `shop-infra` (Helm chart) and
   `shop-acceptance-tests` (the suite).
4. **Build.** `podman build` the candidate into `localhost/shop-order:pr-<N>`.
5. **Load.** `kind load image-archive` puts that image into the `preprod` node.
6. **Baseline.** `helm upgrade --install` makes sure the full stack
   (Postgres/Redis/Kafka + all services) exists (no-op if already there).
7. **Deploy candidate.** `kubectl set image deployment/shop-order ...:pr-<N>` +
   `rollout status` rolls just the changed service to the PR build.
8. **Acceptance.** Port-forward the gateway and run the Cucumber suite
   (`./gradlew test` with `SHOP_GATEWAY_URL`). Each scenario provisions and tears
   down its own data. The JUnit/Cucumber report is uploaded as an artifact.
9. **Result.** Suite green → check **passes** → PR is mergeable. Any failure →
   check **fails** → PR blocked. Cleanup removes the PR image/tar.

Pushing more commits to the PR re-runs the gate automatically (`synchronize`).

## Make the gate REQUIRED (block merge unless green)

Per service repo: **Settings → Branches → Add branch protection rule** for
`main` → *Require status checks to pass* → select **preprod-gate / gate**.
(The check name only appears in the list after the first run, so open one PR
first.) Can also be set via `gh api` once the check has run once.

## Notes / future

- The `gate.yml` and chart are referenced at `@develop_v_0.0.1`. After you merge
  the stack to `main`, bump those refs (and the `INFRA_REF`/`ACCEPTANCE_REF` env)
  to `main`.
- `shop-ui` is intentionally not gated by this API suite; add a Playwright gate
  later (spec already in `shop-ui/features/shopping-journey.feature`).
