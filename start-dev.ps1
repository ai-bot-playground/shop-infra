<#
.SYNOPSIS
  Przywraca srodowisko preprod po starcie komputera / restarcie maszyny podmana
  i dowodzi, ze dziala. Idempotentny: to, co juz dziala, zostawia w spokoju.

.DESCRIPTION
  Kolejnosc (kazdy krok sprawdza stan, zanim cos zrobi):
    1. podman machine            - start, jesli nie dziala
    2. API podmana tcp://IP:2375 - start `podman system service` w maszynie (Testcontainers w bramkach)
    3. kind-preprod              - start kontenera wezla; kubeconfig przepiety na biezace IP maszyny
    4. .env runnerow             - DOCKER_HOST / TESTCONTAINERS_HOST_OVERRIDE na biezace IP
    5. pody                      - czeka, az wszystkie w namespace `shop` beda gotowe
    6. tematy Kafki              - brakujace => helm upgrade (hook odtwarza tematy)
    7. runnery                   - start tych, ktore nie dzialaja (okno per runner)
    8. smoke                     - 3 scenariusze shop-acceptance-tests przez port-forward gatewaya

  Klaster trzyma stan miedzy restartami (release helm, obrazy w wezle, dane na emptyDir),
  wiec domyslnie NIC nie jest przebudowywane ani wdrazane od nowa.

.PARAMETER Deploy
  Dodatkowo deploy-kubernetes-preprod.ps1 (reuse obrazow; z -Full - przebudowa).

.PARAMETER Full
  Razem z -Deploy: przebuduj obrazy przed wdrozeniem.

.PARAMETER Compose
  Dodatkowo stack docker-compose (osobne srodowisko dev; patrz README, "Podman na tej maszynie").

.PARAMETER SkipRunners
  Nie startuj runnerow.

.PARAMETER SkipSmoke
  Bez testu akceptacyjnego na koncu.

.EXAMPLE
  .\start-dev.ps1                 # po restarcie: przywroc i sprawdz
  .\start-dev.ps1 -Deploy -Full   # przywroc, przebuduj obrazy z working tree i wdroz
#>
[CmdletBinding()]
param(
  [switch]$Deploy,
  [switch]$Full,
  [switch]$Compose,
  [switch]$SkipRunners,
  [switch]$SkipSmoke,
  [string]$RunnerRoot = 'C:\actions-runner',
  [string]$Org = 'ai-bot-playground',
  [int]$ApiPort = 6443,
  [int]$SmokePort = 18080
)

# Nie 'Stop': podman/kind/kubectl pisza zwykle komunikaty na stderr, a PowerShell 5.1
# zamienia je wtedy w blad konczacy. Bledy wykrywamy przez $LASTEXITCODE.
$ErrorActionPreference = 'Continue'
$infra = $PSScriptRoot
$root  = Split-Path $infra -Parent
$ctx   = 'kind-preprod'
$ns    = 'shop'
$env:KIND_EXPERIMENTAL_PROVIDER = 'podman'
$runnerServices = 'shop-gateway','shop-catalog','shop-inventory','shop-order',
                  'shop-payment','shop-notification','shop-token-metrics','shop-ui'
$topics = 'order-events','inventory-events','payment-events',
          'order-events.DLT','inventory-events.DLT','payment-events.DLT'
$summary = [ordered]@{}

function Log($m) { Write-Host ("{0}  {1}" -f ([DateTime]::Now.ToString('HH:mm:ss')), $m) -ForegroundColor Cyan }
function Fail($step, $m) { $summary[$step] = "FAIL - $m"; Write-Host "  $m" -ForegroundColor Red }

function Wait-Until([scriptblock]$Condition, [int]$Seconds, [int]$Every = 3) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  do {
    if (& $Condition) { return $true }
    Start-Sleep -Seconds $Every
  } until ((Get-Date) -gt $deadline)
  return [bool](& $Condition)
}

function Get-MachineIp {
  $line = podman machine ssh -- ip -4 -o addr show eth0 2> $null
  $m = [regex]::Match(($line -join ' '), '(\d+\.\d+\.\d+\.\d+)/')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Test-PodmanApi([string]$ip) {
  try { return (Invoke-WebRequest "http://${ip}:2375/_ping" -UseBasicParsing -TimeoutSec 3).Content -eq 'OK' }
  catch { return $false }
}

function Write-SummaryAndExit {
  Write-Host ''
  Log 'Podsumowanie:'
  $failed = $false
  foreach ($k in $summary.Keys) {
    $color = if ($summary[$k] -like 'FAIL*') { $failed = $true; 'Red' } elseif ($summary[$k] -like 'UWAGA*') { 'Yellow' } else { 'Green' }
    Write-Host ("  {0,-14} {1}" -f $k, $summary[$k]) -ForegroundColor $color
  }
  if ($failed) { exit 1 }
  exit 0
}

# --- 1. podman machine ---------------------------------------------------------
Log 'podman machine...'
podman info *> $null
if ($LASTEXITCODE -ne 0) {
  Log '  start podman machine'
  podman machine start
  podman info *> $null
}
if ($LASTEXITCODE -ne 0) {
  Fail 'podman' 'maszyna nie wstaje. Przy Wsl/Service/CreateInstance/CreateVm/HCS/0x80070569: jako admin Get-Service vmcompute | Restart-Service (README).'
  Write-SummaryAndExit
}
$ip = Get-MachineIp
if (-not $ip) { Fail 'podman' 'nie udalo sie odczytac IP maszyny (eth0)'; Write-SummaryAndExit }
$summary['podman'] = "OK (IP $ip)"

# --- 2. API podmana po TCP -----------------------------------------------------
Log "API podmana tcp://${ip}:2375..."
if (-not (Test-PodmanApi $ip)) {
  Log '  start podman system service w maszynie'
  podman machine ssh --username root "nohup podman system service --time=0 tcp://0.0.0.0:2375 >/tmp/pmapi.log 2>&1 &" *> $null
}
if (Wait-Until { Test-PodmanApi $ip } 20 2) { $summary['podman-api'] = 'OK' }
else { Fail 'podman-api' "brak odpowiedzi na http://${ip}:2375/_ping (log w maszynie: /tmp/pmapi.log)" }

# --- 3. kind-preprod -----------------------------------------------------------
Log 'kind-preprod...'
$state = podman inspect --format '{{.State.Status}}' preprod-control-plane 2> $null
if ($LASTEXITCODE -ne 0) {
  Fail 'kind' 'brak kontenera preprod-control-plane - postaw klaster: .\create-kind-preprod.ps1, potem .\deploy-kubernetes-preprod.ps1'
  Write-SummaryAndExit
}
if ($state -ne 'running') {
  Log "  start wezla (stan: $state)"
  podman start preprod-control-plane *> $null
}
$want = "https://${ip}:$ApiPort"
# JSON zamiast filtra jsonpath: PowerShell 5.1 gubi cudzyslowy w argumentach natywnych.
$server = ((kubectl config view -o json 2> $null | Out-String | ConvertFrom-Json).clusters |
  Where-Object { $_.name -eq $ctx }).cluster.server
if ($server -ne $want) {
  Log "  kubeconfig: $server -> $want"
  kubectl config set-cluster kind-preprod --server=$want --tls-server-name=localhost *> $null
}
if (Wait-Until { (kubectl --context $ctx get nodes --no-headers 2> $null) -match '\bReady\b' } 180 5) {
  $summary['kind'] = 'OK (wezel Ready)'
} else {
  Fail 'kind' "wezel nie jest Ready po 180 s (kubectl --context $ctx get nodes)"
  Write-SummaryAndExit
}

# --- 4. .env runnerow ----------------------------------------------------------
Log "runnery: .env ($RunnerRoot)..."
$envChanged = @()
foreach ($svc in $runnerServices) {
  $file = Join-Path $RunnerRoot "$svc\.env"
  if (-not (Test-Path (Join-Path $RunnerRoot $svc))) { continue }
  $lines = if (Test-Path $file) { @(Get-Content $file) } else { @() }
  $wantVars = [ordered]@{
    DOCKER_HOST                  = "tcp://${ip}:2375"
    TESTCONTAINERS_HOST_OVERRIDE = $ip
    TESTCONTAINERS_RYUK_DISABLED = 'true'
  }
  $new = @($lines | Where-Object { $_ -notmatch '^(DOCKER_HOST|TESTCONTAINERS_HOST_OVERRIDE|TESTCONTAINERS_RYUK_DISABLED)=' })
  foreach ($k in $wantVars.Keys) { $new += "$k=$($wantVars[$k])" }
  if ((($lines | Sort-Object) -join "`n") -ne (($new | Sort-Object) -join "`n")) {
    Set-Content -Path $file -Value $new -Encoding ascii
    $envChanged += $svc
  }
}
$summary['runner-env'] = if ($envChanged) { "zaktualizowane: $($envChanged -join ', ')" } else { 'OK (bez zmian)' }

# --- 5. pody -------------------------------------------------------------------
Log "pody w namespace $ns (max 5 min)..."
$podsOk = Wait-Until {
  $p = kubectl --context $ctx -n $ns get pods --no-headers 2> $null
  $p -and -not ($p | Where-Object { $_ -notmatch '\s(\d+)/\1\s+Running\s' })
} 300 10
$pods = kubectl --context $ctx -n $ns get pods --no-headers 2> $null
$notReady = @($pods | Where-Object { $_ -notmatch '\s(\d+)/\1\s+Running\s' })
if ($podsOk) { $summary['pods'] = "OK ($(@($pods).Count) gotowych)" }
else { Fail 'pods' "niegotowe: $(($notReady | ForEach-Object { ($_ -split '\s+')[0] }) -join ', ')" }

# --- 6. tematy Kafki -----------------------------------------------------------
# Od shop-infra#3 log Kafki lezy na emptyDir i przezywa restart wezla. Gdy jednak tematow
# brak (np. pod Kafki zostal usuniety), odtwarza je tylko hook post-upgrade charta.
Log 'tematy Kafki...'
$have = @(kubectl --context $ctx -n $ns exec deploy/shop-kafka -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list 2> $null)
$missing = @($topics | Where-Object { $have -notcontains $_ })
if ($missing) {
  Log "  brak: $($missing -join ', ') - helm upgrade (hook odtwarza tematy)"
  helm upgrade --install shop (Join-Path $infra 'helm') --kube-context $ctx -n $ns `
    -f (Join-Path $infra 'helm\values.yaml') -f (Join-Path $infra 'helm\values-preprod.yaml') `
    --force-conflicts --timeout 6m --wait *> $null
  $have = @(kubectl --context $ctx -n $ns exec deploy/shop-kafka -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list 2> $null)
  $missing = @($topics | Where-Object { $have -notcontains $_ })
}
if ($missing) { Fail 'kafka' "nadal brak tematow: $($missing -join ', ')" }
else { $summary['kafka'] = "OK ($($topics.Count) tematow)" }

# --- 7. runnery ----------------------------------------------------------------
if ($SkipRunners) {
  $summary['runners'] = 'pominiete (-SkipRunners)'
} else {
  Log 'runnery...'
  # Zrodlo prawdy to status na GitHubie, nie lista procesow: procesu runnera uruchomionego
  # z okna o innych uprawnieniach (np. admin) nie widac (ExecutablePath = null), a start
  # "brakujacego" dublowalby dzialajacy runner.
  function Get-RunnerStatus([string]$svc) {
    $json = gh api "repos/$Org/$svc/actions/runners" 2> $null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    $r = ($json | Out-String | ConvertFrom-Json).runners | Where-Object { $_.name -eq $svc } | Select-Object -First 1
    if ($r) { return $r.status } else { return 'unregistered' }
  }
  $listeners = @(Get-CimInstance Win32_Process -Filter "Name='Runner.Listener.exe'" -ErrorAction SilentlyContinue)
  $started = @(); $restarted = @(); $manual = @(); $missingRunner = @(); $unknown = @()
  foreach ($svc in $runnerServices) {
    $dir = Join-Path $RunnerRoot $svc
    if (-not (Test-Path (Join-Path $dir '.runner'))) { $missingRunner += $svc; continue }
    $status = Get-RunnerStatus $svc
    if (-not $status) { $unknown += $svc; continue }
    if ($status -eq 'unregistered') { $missingRunner += $svc; continue }
    $visible = @($listeners | Where-Object { $_.ExecutablePath -like "$dir\*" })
    if ($status -eq 'online' -and $envChanged -contains $svc) {
      # Runner czyta .env tylko przy starcie - po zmianie IP trzeba go podniesc od nowa.
      if ($visible) {
        $visible | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        $status = 'offline'; $restarted += $svc
      } else { $manual += $svc }
    }
    if ($status -ne 'online') {
      Start-Process powershell -WindowStyle Minimized -ArgumentList '-NoExit','-Command',"Set-Location '$dir'; .\run.cmd"
      if ($restarted -notcontains $svc) { $started += $svc }
    }
  }
  $touched = @($started + $restarted)
  $stillOffline = @()
  if ($touched) {
    Wait-Until { -not @($touched | Where-Object { (Get-RunnerStatus $_) -ne 'online' }) } 90 10 | Out-Null
    $stillOffline = @($touched | Where-Object { (Get-RunnerStatus $_) -ne 'online' })
  }
  $parts = @()
  if ($started)   { $parts += "uruchomione: $($started -join ', ')" }
  if ($restarted) { $parts += "zrestartowane (nowe IP): $($restarted -join ', ')" }
  if (-not $parts) { $parts += 'OK (wszystkie online)' }
  $warn = @()
  if ($stillOffline)  { $warn += "nadal offline: $($stillOffline -join ', ')" }
  if ($manual)        { $warn += "zrestartuj recznie (nowe IP w .env, proces niewidoczny): $($manual -join ', ')" }
  if ($missingRunner) { $warn += "niezarejestrowane: $($missingRunner -join ', ') (.\register-preprod-runners.ps1)" }
  if ($unknown)       { $warn += "brak statusu z GitHuba (gh auth status?) - nie startuje: $($unknown -join ', ')" }
  $summary['runners'] = if ($warn) { "UWAGA - $($warn -join '; '); " + ($parts -join '; ') } else { $parts -join '; ' }
}

# --- opcjonalnie: deploy / compose ---------------------------------------------
if ($Deploy) {
  $deployArgs = @('-SkipQaUi')
  if (-not $Full) { $deployArgs += '-SkipBuild' }
  Log "deploy-kubernetes-preprod.ps1 $($deployArgs -join ' ')..."
  & (Join-Path $infra 'deploy-kubernetes-preprod.ps1') @deployArgs
  $summary['deploy'] = if ($LASTEXITCODE -eq 0) { 'OK' } else { "FAIL - exit $LASTEXITCODE" }
}
if ($Compose) {
  Log 'docker-compose up -d (przez API podmana na IP maszyny)...'
  $env:DOCKER_HOST = "tcp://${ip}:2375"
  Push-Location $infra
  try { docker-compose up -d } finally { Pop-Location }
  $summary['compose'] = if ($LASTEXITCODE -eq 0) { "OK (porty pod http://${ip}:<port>)" } else { "FAIL - exit $LASTEXITCODE" }
}

# --- 8. smoke: scenariusze akceptacyjne ----------------------------------------
if ($SkipSmoke) {
  $summary['smoke'] = 'pominiete (-SkipSmoke)'
} else {
  Log "smoke: shop-acceptance-tests przez port-forward :$SmokePort..."
  $pf = Start-Job { kubectl --context $using:ctx -n $using:ns port-forward svc/shop-gateway "$($using:SmokePort):8080" }
  try {
    $up = Wait-Until {
      try { (Invoke-WebRequest "http://localhost:$SmokePort/actuator/health" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } catch { $false }
    } 40 2
    if (-not $up) {
      Fail 'smoke' "gateway nieosiagalny na localhost:$SmokePort"
    } else {
      $env:SHOP_GATEWAY_URL = "http://localhost:$SmokePort"
      Push-Location (Join-Path $root 'shop-acceptance-tests')
      try {
        # cleanTest: bez niego Gradle uznaje `test` za UP-TO-DATE i nic nie sprawdza.
        & .\gradlew.bat cleanTest test --no-daemon -q --console=plain *> $null
        $ok = $LASTEXITCODE -eq 0
        $xml = Get-ChildItem 'build\test-results\test' -Filter *.xml -ErrorAction SilentlyContinue | Select-Object -First 1
        $suite = if ($xml) { ([xml](Get-Content $xml.FullName)).testsuite } else { $null }
        $result = if ($suite) { "$([int]$suite.tests - [int]$suite.failures - [int]$suite.errors)/$($suite.tests)" } else { '?' }
        if ($ok) { $summary['smoke'] = "OK (akceptacja $result)" }
        else { Fail 'smoke' "akceptacja $result - raport: shop-acceptance-tests\build\reports\tests\test\index.html" }
      } finally { Pop-Location }
    }
  } finally {
    Stop-Job $pf -ErrorAction SilentlyContinue
    Remove-Job $pf -ErrorAction SilentlyContinue
  }
}

Write-SummaryAndExit
