<#
.SYNOPSIS
  Uruchamia całe środowisko developerskie po starcie komputera.
  Kolejność: podman machine → kind-preprod → podman compose → k8s deploy + runnery + port-forward.

.PARAMETER Full
  Przebuduj obrazy Docker przed deployem na k8s (domyślnie reuse istniejących obrazów).

.EXAMPLE
  .\start-dev.ps1           # szybki start po restarcie — reuse obrazów
  .\start-dev.ps1 -Full     # pełny rebuild obrazów przed deployem na k8s
#>
[CmdletBinding()]
param([switch]$Full)

$ErrorActionPreference = 'Stop'
$infra = $PSScriptRoot
$env:KIND_EXPERIMENTAL_PROVIDER = 'podman'

function Log($m) { Write-Host ("{0}  {1}" -f ([DateTime]::Now.ToString('HH:mm:ss')), $m) -ForegroundColor Cyan }

# --- 1. Podman machine --------------------------------------------------------
Log "Podman machine..."
podman info *> $null
if ($LASTEXITCODE -ne 0) {
  Log "  starting podman machine..."
  podman machine start
  if ($LASTEXITCODE -ne 0) { throw "podman machine start failed" }
} else { Log "  already running" }

# --- 2. Kind-preprod node -----------------------------------------------------
Log "kind-preprod node..."
$state = podman inspect --format "{{.State.Status}}" preprod-control-plane 2> $null
if ($state -ne 'running') {
  podman start preprod-control-plane
  if ($LASTEXITCODE -ne 0) { throw "podman start preprod-control-plane failed" }
}

Log "Waiting for kind-preprod node Ready (max 120s)..."
$deadline = (Get-Date).AddSeconds(120)
do {
  Start-Sleep -Seconds 3
  $ready = (kubectl --context kind-preprod get nodes --no-headers 2> $null) -match '\bReady\b'
} until ($ready -or (Get-Date) -gt $deadline)
if (-not $ready) { throw "kind-preprod node not Ready after 120s" }
Log "  kind-preprod Ready"

# --- 3. Docker Compose --------------------------------------------------------
Log "Docker Compose up (detached)..."
Push-Location $infra
try {
  podman compose up -d
  if ($LASTEXITCODE -ne 0) { throw "podman compose up failed" }
} finally { Pop-Location }

# --- 4. k8s deploy + runnery + port-forward -----------------------------------
$deployArgs = if ($Full) { @() } else { @('-SkipBuild') }
Log "k8s deploy$(if ($Full) { ' (full rebuild)' } else { ' (SkipBuild — reuse images)' })..."
& (Join-Path $infra 'deploy-kubernetes-preprod.ps1') @deployArgs
