<#
.SYNOPSIS
  Tworzy klaster kind `preprod` (provider podman) i ustawia kontekst `kind-preprod` tak,
  by byl osiagalny z Windowsa.

.DESCRIPTION
  Na tej maszynie porty kontenerow NIE sa osiagalne pod localhost (patrz README,
  "Podman na tej maszynie"), wiec domyslny klaster kind (API na 127.0.0.1 w maszynie WSL)
  jest z Windowsa martwy. Dlatego:
    - API server publikujemy na wszystkich interfejsach maszyny (apiServerAddress 0.0.0.0),
    - kubeconfig wskazuje na https://<IP-maszyny>:<ApiPort>,
    - tls-server-name=localhost - certyfikat kind zawsze ma SAN "localhost", wiec po zmianie
      IP maszyny (restart) wystarczy przepiac adres, bez nowego certyfikatu.

.PARAMETER ApiPort
  Port API servera na maszynie WSL (domyslnie 6443).

.PARAMETER Recreate
  Usun istniejacy klaster `preprod` i utworz go od nowa.

.PARAMETER RefreshKubeconfig
  Nie tworz klastra - tylko przepnij kontekst kind-preprod na biezace IP maszyny.

.EXAMPLE
  .\create-kind-preprod.ps1                     # nowy klaster
  .\create-kind-preprod.ps1 -RefreshKubeconfig  # po restarcie podman machine (nowe IP)
#>
[CmdletBinding()]
param(
  [int]$ApiPort = 6443,
  [switch]$Recreate,
  [switch]$RefreshKubeconfig
)

# Nie 'Stop': kind i podman pisza zwykle komunikaty na stderr, a PowerShell 5.1 zamienia je
# wtedy w blad konczacy. Bledy wykrywamy przez $LASTEXITCODE.
$ErrorActionPreference = 'Continue'
$env:KIND_EXPERIMENTAL_PROVIDER = 'podman'

function Log($m) { Write-Host ("{0}  {1}" -f ([DateTime]::Now.ToString('HH:mm:ss')), $m) -ForegroundColor Cyan }

function Get-MachineIp {
  $line = podman machine ssh -- ip -4 -o addr show eth0
  $m = [regex]::Match(($line -join ' '), '(\d+\.\d+\.\d+\.\d+)/')
  if (-not $m.Success) { throw "nie udalo sie odczytac IP maszyny podman (eth0)" }
  $m.Groups[1].Value
}

function Set-PreprodKubeconfig([string]$ip) {
  kubectl config set-cluster kind-preprod --server="https://${ip}:$ApiPort" --tls-server-name=localhost | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "kubectl config set-cluster failed" }
  Log "kubeconfig: kind-preprod -> https://${ip}:$ApiPort (tls-server-name=localhost)"
}

$ip = Get-MachineIp
Log "IP maszyny podman: $ip"

if (-not $RefreshKubeconfig) {
  $exists = (kind get clusters 2> $null) -contains 'preprod'
  if ($exists -and $Recreate) {
    Log "Usuwam istniejacy klaster preprod..."
    kind delete cluster --name preprod
    $exists = $false
  }
  if ($exists) {
    Log "Klaster preprod juz istnieje - pomijam tworzenie (uzyj -Recreate, by postawic od nowa)."
  } else {
    $cfg = Join-Path ([IO.Path]::GetTempPath()) 'kind-preprod.yaml'
    @"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: preprod
networking:
  apiServerAddress: "0.0.0.0"
  apiServerPort: $ApiPort
nodes:
  - role: control-plane
"@ | Set-Content -Encoding ascii $cfg
    Log "Tworze klaster preprod (pierwszy raz pobiera obraz kindest/node)..."
    kind create cluster --config $cfg --wait 180s
    if ($LASTEXITCODE -ne 0) { throw "kind create cluster failed" }
  }
}

Set-PreprodKubeconfig $ip

$deadline = (Get-Date).AddSeconds(120)
do {
  Start-Sleep -Seconds 3
  $ready = (kubectl --context kind-preprod get nodes --no-headers 2> $null) -match '\bReady\b'
} until ($ready -or (Get-Date) -gt $deadline)
if (-not $ready) { throw "wezel kind-preprod nie jest Ready po 120 s" }
Log "kind-preprod Ready"
