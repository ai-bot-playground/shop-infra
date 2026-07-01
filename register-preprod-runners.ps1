<#
.SYNOPSIS
  Register ONE GitHub Actions self-hosted runner per gated service repo, each in
  its own folder C:\actions-runner\<svc>, named + labelled after the repo. The
  preprod gate routes to them via `runs-on: [self-hosted, <service>]`.

.DESCRIPTION
  For each gated repo it: gets a short-lived registration token via `gh`
  (needs repo admin — you already have it), downloads the runner once, extracts
  it into the repo's own folder and configures it unattended (label+name = repo).

  Run in a NORMAL (non-elevated) user PowerShell so the runners belong to YOU and
  can see ~/.kube/config + the podman machine + the kind-preprod context.

  Prerequisites: `gh auth status` logged in (scopes: repo), plus podman + kind +
  kubectl + helm + Java 25 on PATH (same machine as the kind-preprod cluster).

.PARAMETER Start
  After configuring, launch each runner in its OWN foreground window (runs as you).

.PARAMETER InstallService
  Instead of foreground, install+start each runner as a Windows service. NOTE:
  run an ELEVATED PowerShell for this, and make the service log on as YOUR user
  (Services -> actions.runner.* -> Log On) or it won't see kubeconfig/podman.

.EXAMPLE
  # configure all 8 runners, then run them in foreground windows:
  .\register-preprod-runners.ps1 -Start

.EXAMPLE
  # register (or re-register) only the shop-ui runner:
  .\register-preprod-runners.ps1 -Services shop-ui -Start
#>
[CmdletBinding()]
param(
  [string]$Org = 'ai-bot-playground',
  [string]$RunnerRoot = 'C:\actions-runner',
  # shop-ui ma wlasna bramke (ui-preprod-gate: npm+vite -> obraz -> kind -> smoke),
  # ale routuje na runner tak samo: runs-on [self-hosted, shop-ui]. Node dostarcza
  # actions/setup-node w workflow, wiec runner nie wymaga Node na PATH.
  [string[]]$Services = @('shop-gateway','shop-catalog','shop-inventory','shop-order',
                          'shop-payment','shop-notification','shop-token-metrics','shop-ui'),
  [switch]$Start,
  [switch]$InstallService
)
$ErrorActionPreference = 'Stop'

# --- prerequisites -----------------------------------------------------------
gh auth status 1>$null   # throws if not logged in

Write-Host "Resolving latest runner version ..."
$ver = (gh api repos/actions/runner/releases/latest --jq .tag_name).TrimStart('v')
$zip = Join-Path $env:TEMP "actions-runner-win-x64-$ver.zip"
$url = "https://github.com/actions/runner/releases/download/v$ver/actions-runner-win-x64-$ver.zip"
if (-not (Test-Path $zip)) {
  Write-Host "Downloading runner $ver -> $zip"
  Invoke-WebRequest -Uri $url -OutFile $zip
} else {
  Write-Host "Runner $ver already downloaded ($zip)"
}

# --- one runner per repo -----------------------------------------------------
foreach ($svc in $Services) {
  $dir = Join-Path $RunnerRoot $svc
  Write-Host "`n=== $svc -> $dir ==="

  if (Test-Path (Join-Path $dir '.runner')) {
    Write-Host "  already configured; skipping (delete $dir to re-register)"
  } else {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Expand-Archive -Path $zip -DestinationPath $dir -Force

    Write-Host "  fetching registration token ..."
    $token = gh api -X POST "repos/$Org/$svc/actions/runners/registration-token" --jq .token
    if (-not $token) { throw "no registration token for $svc (need repo admin)" }

    Push-Location $dir
    try {
      & .\config.cmd --url "https://github.com/$Org/$svc" --token $token `
        --labels $svc --name $svc --unattended --replace
      if ($LASTEXITCODE -ne 0) { throw "config.cmd failed for $svc (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
    Write-Host "  configured: name=$svc label=$svc"
  }

  if ($InstallService) {
    Push-Location $dir
    try {
      & .\svc.cmd install
      & .\svc.cmd start
    } finally { Pop-Location }
  }
}

# --- start (foreground, one window each) -------------------------------------
if ($Start) {
  foreach ($svc in $Services) {
    $dir = Join-Path $RunnerRoot $svc
    Start-Process powershell -ArgumentList '-NoExit','-Command',"Set-Location '$dir'; .\run.cmd"
  }
  Write-Host "`nLaunched $($Services.Count) runner windows. Each should read 'Listening for Jobs'."
} elseif (-not $InstallService) {
  Write-Host "`nConfigured. To run them now:  .\register-preprod-runners.ps1 -Start"
  Write-Host "Or per repo:  cd C:\actions-runner\<svc>; .\run.cmd"
}

# --- verify on GitHub --------------------------------------------------------
Write-Host "`n=== repo-level runners ==="
foreach ($svc in $Services) {
  $r = gh api "repos/$Org/$svc/actions/runners" | ConvertFrom-Json
  $s = if ($r.total_count -eq 0) { 'none' } else { ($r.runners | ForEach-Object { "$($_.name):$($_.status)" }) -join ', ' }
  "{0,-22} {1}" -f $svc, $s
}
