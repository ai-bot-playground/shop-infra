<#
.SYNOPSIS
  Deploy the whole shop stack onto the local kind-preprod cluster from the code
  CURRENTLY CHECKED OUT in each repo. This script never runs `git checkout` /
  changes branches — it builds whatever working tree is present.

.DESCRIPTION
  Components (as requested), and how each is deployed:
    * shop-catalog / gateway / inventory / order / payment / notification /
      token-metrics / ui  -> image built from the repo working tree
      (localhost/<svc>:0.0.1), loaded into kind, deployed by the Helm chart.
    * shop-postgres / redis / kafka -> brought up in-cluster by the SAME Helm
      chart (upstream images; the repos hold only seed/config, e.g.
      01-create-databases.sql / redis.conf, baked into the chart).
    * shop-infra -> IS the Helm chart used for `helm upgrade --install` (the
      deploy mechanism itself), applied from its current working tree.
    * shop-qa-ui -> separate app: image legacy-documenter:dev built from the repo,
      loaded into kind, applied via its own kustomize (deploy/k8s, namespace
      `legacy-documenter`). Needs a `legacy-documenter-secrets` secret (OpenRouter
      key) — created here if missing (placeholder unless -OpenRouterApiKey /
      $env:OPENROUTER_API_KEY).
    * shop-acceptance-tests -> not a cluster workload; it's the E2E suite. Run it
      against the freshly deployed stack with -RunAcceptance.

.PARAMETER SkipBuild
  Skip `podman build`; reuse whatever images already exist, then just
  re-apply the chart and roll the deployments.

.PARAMETER SkipQaUi
  Do not build/deploy shop-qa-ui.

.PARAMETER RunAcceptance
  After deploy, run shop-acceptance-tests\run-local.ps1 (the Cucumber E2E suite).

.PARAMETER OpenRouterApiKey
  Value for the qa-ui secret OPENROUTER_API_KEY (defaults to $env:OPENROUTER_API_KEY).

.EXAMPLE
  .\deploy-preprod.ps1
  .\deploy-preprod.ps1 -SkipQaUi -RunAcceptance
#>
[CmdletBinding()]
param(
  [switch]$SkipBuild,
  [switch]$SkipQaUi,
  [switch]$RunAcceptance,
  [string]$OpenRouterApiKey = $env:OPENROUTER_API_KEY
)

$env:KIND_EXPERIMENTAL_PROVIDER = 'podman'
$infra = $PSScriptRoot
$root  = Split-Path $PSScriptRoot -Parent
$ctx   = 'kind-preprod'
$ns    = 'shop'
$tag   = '0.0.1'
$cluster = 'preprod'

# Spring/web services that ship as localhost/<svc>:0.0.1 and live in the chart.
$appServices = 'shop-gateway','shop-catalog','shop-inventory','shop-order',
               'shop-payment','shop-notification','shop-token-metrics','shop-ui'

function Log($m) { Write-Host ("{0}  {1}" -f ([DateTime]::Now.ToString('HH:mm:ss')), $m) -ForegroundColor Cyan }
function Die($m) { throw $m }

# --- preflight ---------------------------------------------------------------
Log "Preflight: kind-preprod reachable?"
kubectl --context $ctx get nodes *> $null
if ($LASTEXITCODE -ne 0) { Die "kind-preprod not reachable. Start it: podman machine start; podman start preprod-control-plane" }

Log "Deploying from the CURRENTLY CHECKED-OUT code of each repo (no branch change):"
foreach ($r in ($appServices + 'shop-infra','shop-postgres','shop-redis','shop-kafka','shop-acceptance-tests','shop-qa-ui')) {
  $d = Join-Path $root $r
  if (Test-Path (Join-Path $d '.git')) {
    $b = (git -C $d rev-parse --abbrev-ref HEAD)
    "    {0,-22} {1}" -f $r, $b
  }
}

# --- build images (from working tree) ----------------------------------------
if (-not $SkipBuild) {
  foreach ($s in $appServices) {
    Log "BUILD $s -> localhost/$($s):$tag"
    podman build -t "localhost/$($s):$tag" (Join-Path $root $s)
    if ($LASTEXITCODE -ne 0) { Die "podman build failed for $s" }
  }
  if (-not $SkipQaUi) {
    Log "BUILD shop-qa-ui -> legacy-documenter:dev"
    podman build -f (Join-Path $root 'shop-qa-ui\Containerfile') -t 'legacy-documenter:dev' (Join-Path $root 'shop-qa-ui')
    if ($LASTEXITCODE -ne 0) { Die "podman build failed for shop-qa-ui" }
  }
} else { Log "SkipBuild: reusing existing images" }

# --- load images into the kind node ------------------------------------------
$imgs = $appServices | ForEach-Object { "localhost/$($_):$tag" }
if (-not $SkipQaUi) { $imgs += 'legacy-documenter:dev' }
$tar = Join-Path $env:TEMP 'shop-preprod-imgs.tar'
Log "SAVE $($imgs.Count) images -> $tar"
podman save -o $tar @imgs
if ($LASTEXITCODE -ne 0) { Die "podman save failed" }
Log "KIND LOAD -> $cluster node"
kind load image-archive $tar --name $cluster
if ($LASTEXITCODE -ne 0) { Die "kind load failed" }
Remove-Item -Force $tar -ErrorAction SilentlyContinue

# --- helm: deploys app services + postgres + redis + kafka (infra chart) -----
Log "HELM upgrade --install (chart from shop-infra working tree): services + postgres/redis/kafka"
helm upgrade --install shop (Join-Path $infra 'helm') --kube-context $ctx -n $ns --create-namespace `
  -f (Join-Path $infra 'helm\values.yaml') -f (Join-Path $infra 'helm\values-preprod.yaml') `
  --force-conflicts --timeout 6m
if ($LASTEXITCODE -ne 0) { Die "helm upgrade failed" }

# Fixed image tag (:0.0.1) => helm sees no change; force pods onto the freshly
# loaded images (imagePullPolicy: IfNotPresent reuses the node copy).
foreach ($s in $appServices) {
  kubectl --context $ctx -n $ns rollout restart "deployment/$s" *> $null
  if ($LASTEXITCODE -ne 0) { Die "rollout restart failed for $s" }
}
foreach ($s in $appServices) {
  Log "ROLLOUT $s"
  kubectl --context $ctx -n $ns rollout status "deployment/$s" --timeout=180s
  if ($LASTEXITCODE -ne 0) { Die "rollout status failed for $s" }
}

# --- shop-qa-ui (separate namespace, own kustomize) --------------------------
if (-not $SkipQaUi) {
  $qns = 'legacy-documenter'
  Log "QA-UI: namespace + secret + kustomize ($qns)"
  kubectl --context $ctx get ns $qns *> $null
  if ($LASTEXITCODE -ne 0) { kubectl --context $ctx create ns $qns | Out-Null }

  kubectl --context $ctx -n $qns get secret legacy-documenter-secrets *> $null
  if ($LASTEXITCODE -ne 0) {
    $key = if ($OpenRouterApiKey) { $OpenRouterApiKey } else { 'REPLACE_ME' }
    kubectl --context $ctx -n $qns create secret generic legacy-documenter-secrets --from-literal=OPENROUTER_API_KEY=$key | Out-Null
    if (-not $OpenRouterApiKey) { Write-Warning "qa-ui: created legacy-documenter-secrets with a PLACEHOLDER. Set -OpenRouterApiKey or `$env:OPENROUTER_API_KEY for real LLM calls." }
  }

  kubectl --context $ctx apply -k (Join-Path $root 'shop-qa-ui\deploy\k8s')
  if ($LASTEXITCODE -ne 0) { Die "kubectl apply -k (qa-ui) failed" }
  kubectl --context $ctx -n $qns rollout restart deployment/legacy-documenter *> $null
  Log "ROLLOUT legacy-documenter"
  kubectl --context $ctx -n $qns rollout status deployment/legacy-documenter --timeout=180s
  if ($LASTEXITCODE -ne 0) { Die "rollout status failed for qa-ui" }
}

# --- summary -----------------------------------------------------------------
Log "DONE. Pods:"
kubectl --context $ctx -n $ns get pods
if (-not $SkipQaUi) { kubectl --context $ctx -n 'legacy-documenter' get pods }

# --- optional: acceptance E2E suite against the deployed stack ---------------
if ($RunAcceptance) {
  Log "ACCEPTANCE: shop-acceptance-tests\run-local.ps1"
  & (Join-Path $root 'shop-acceptance-tests\run-local.ps1')
  if ($LASTEXITCODE -ne 0) { Die "acceptance suite failed" }
}
