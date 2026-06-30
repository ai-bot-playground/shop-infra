# Self-hosted runner + preprod merge gate

How a PR into `main` is gated by a full end-to-end run on the local
`kind-preprod` cluster, and what you must install once.

> **Daily clean start** of the local infra (podman → kind → runner) so the gate
> works when you open a PR: see [LOCAL-START.md](LOCAL-START.md).

## What you install (once) — the only manual step

One **GitHub Actions self-hosted runner per service repo**, each registered at
the **repository** level and **named + labelled after that repo** (so in each
repo's *Settings → Actions → Runners* you see exactly one runner whose name is
the repo name). They all run on **this machine, as your own user** (so they share
your kubeconfig + podman machine + the one local kind-preprod cluster).

Gated service repos — one runner each:
`shop-gateway`, `shop-catalog`, `shop-inventory`, `shop-order`, `shop-payment`,
`shop-notification`, `shop-token-metrics`.

For **each** repo `<svc>` above:

1. GitHub → repo `ai-bot-playground/<svc>` → **Settings → Actions → Runners →
   New self-hosted runner** → Windows / x64. Copy the `--url` (it will be
   `https://github.com/ai-bot-playground/<svc>`) and the short-lived `--token`.
2. In a normal user PowerShell — give each runner its OWN folder so they don't
   collide:
   ```powershell
   mkdir C:\actions-runner\<svc>; cd C:\actions-runner\<svc>
   # download URL is shown on the same GitHub page (actions-runner-win-x64-*.zip)
   Invoke-WebRequest -Uri <RUNNER_ZIP_URL> -OutFile runner.zip
   Expand-Archive runner.zip -DestinationPath .
   .\config.cmd --url https://github.com/ai-bot-playground/<svc> --token <TOKEN> `
     --labels <svc> --name <svc> --unattended
   ```
   `self-hosted` and `Windows`/`X64` labels are added automatically; the extra
   `--labels <svc>` is what the gate targets (`runs-on: [self-hosted, <svc>]`),
   and `--name <svc>` is what you see in that repo's runner list.
3. Run it (foreground for the first test, then install as a service):
   ```powershell
   .\run.cmd                 # foreground
   # or, to persist across reboots (run elevated once):
   .\svc.cmd install; .\svc.cmd start
   ```
   > If you install runners as **services**, make sure each service account is
   > **your user** (not LocalSystem) — otherwise they won't see `~/.kube/config`,
   > the `kind-preprod` context or the podman machine.

> All runners share the one local kind-preprod cluster and the one helm release,
> so the gate's deploy step takes a machine-local mutex (`Global\shop-preprod-gate`)
> — only ONE gate touches the cluster at a time, even with a PR open on every repo.
> (GitHub `concurrency` can't enforce this across repos; its groups are
> repo-scoped. All runners being on one machine is what makes the mutex work.)

### Runner prerequisites (already true on this machine)

`podman`, `kind`, `kubectl`, `helm`, `git`, `curl` and **Java 25** on the runner
user's PATH, the **podman machine running**, and the **`kind-preprod` cluster up
with the baseline stack deployed** (see `HANDOFF.md` runbook). The gate
re-applies the chart (`helm upgrade --install`, idempotent) but relies on the
baseline `:0.0.1` images of the *other* services already being loaded in the node.

## How the gate fires when you open a PR

Files involved:
- `shop-<service>/.github/workflows/pr-to-main.yml` — tiny trigger, one per
  application service (gateway, catalog, inventory, order, payment, notification,
  token-metrics).
- `shop-acceptance-tests/.github/workflows/gate.yml` — the reusable gate it calls.

Step by step, for e.g. a PR `shop-order: feature-x → main`:

1. **Trigger.** GitHub reads `pr-to-main.yml` from the PR head branch and sees
   `on: pull_request` (ANY base branch) → a check run **preprod-gate / gate**
   appears on the PR and is queued onto THIS repo's own
   `[self-hosted, shop-order]` runner.
2. **Serialize.** All repos share one cluster, so the gate's deploy step takes a
   machine-local mutex (`Global\shop-preprod-gate`): only one gate runs load →
   deploy → acceptance at a time; the others block until it releases. (`concurrency:
   preprod-gate` only serializes runs *within* a single repo — GitHub concurrency
   groups are repo-scoped — so it can't coordinate across the per-repo runners.)
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

## Status

- Each gated service repo runs its gate on **its own repo-level runner**
  (`runs-on: [self-hosted, <service>]`). Register one runner per repo as above
  (name + label = repo name) before opening PRs in that repo.
- The gate fires for a PR to **any** base branch and deploys onto the local
  kind-preprod cluster (component tests → build → load → deploy candidate →
  acceptance).
- Branch protection requiring the `preprod-gate / gate` status check can stay
  enabled per service repo — the check name is unchanged.

## Notes / gotchas / future

- **Gate steps run in PowerShell, not bash.** On a Windows self-hosted runner
  `shell: bash` resolves to `C:\Windows\System32\bash.exe` (the WSL launcher),
  which mangles Windows script paths and has no podman/kubectl — every bash step
  fails with `No such file or directory`. The gate therefore uses
  `defaults.run.shell: powershell`.
- Self-hosted runners on **public** repos carry a security warning (a fork's PR
  could run code on your machine) — GitHub makes you confirm this when adding a
  repo-level runner to a public repo. For stronger isolation, make the repos
  private instead.
- The `gate.yml` and chart are referenced at `@main` — in each service's
  `pr-to-main.yml` (`uses: ...gate.yml@main`) and the gate's two
  `actions/checkout` refs (`ref: main` for shop-infra and shop-acceptance-tests).
  So the gate always builds the candidate service against the **`main`** branch of
  the chart and the acceptance suite; the apps on kind-preprod are always built
  from `main`.
- `shop-ui` is intentionally not gated by this API suite; add a Playwright gate
  later (spec already in `shop-ui/features/shopping-journey.feature`).
