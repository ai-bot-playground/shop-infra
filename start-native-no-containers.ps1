# start-native-no-containers.ps1
#
# ŚCIEŻKA AWARYJNA: uruchamia cały stack sklepu BEZ kontenerów.
#
# Kiedy jej użyć: gdy `podman machine start` pada na
#     Wsl/Service/CreateInstance/CreateVm/HCS/0x80070569
# czyli ERROR_LOGON_TYPE_NOT_GRANTED. WSL nie tworzy wtedy ŻADNEJ maszyny
# (sprawdź: `wsl -d Ubuntu -- echo ok`), więc nie działa ani `podman compose up`,
# ani kind-preprod, ani Testcontainers. Naprawa wymaga uprawnień administratora
# (przywrócenie prawa „Log on as a service" dla NT VIRTUAL MACHINE\Virtual Machines) —
# do czasu naprawy ten skrypt pozwala uruchomić i zweryfikować system lokalnie.
#
# Czego NIE zastępuje: bramki `preprod-gate`, klastra kind ani testów
# komponentowych na Testcontainers — te nadal wymagają działających kontenerów.
#
# Wymagania (poza JDK 25 i Node): natywne buildy Postgresa, Redisa i Kafki
# rozpakowane w $InfraRoot. Skrypt pobiera je sam przy pierwszym uruchomieniu.
#
#   .\start-native-no-containers.ps1            # infrastruktura + serwisy
#   .\start-native-no-containers.ps1 -Stop      # zatrzymanie wszystkiego
#
# Mapowanie 1:1 z docker-compose.yml — te same zmienne środowiskowe, tylko
# nazwy hostów (postgres / redis / shop-kafka / shop-catalog…) zamienione na
# localhost, a każdy serwis dostaje własny port.

[CmdletBinding()]
param(
  [switch]$Stop,
  [switch]$SkipInfra,
  # 8080 bywa zajęte przez inne narzędzia deweloperskie — bramka jest przestawialna.
  [int]$GatewayPort = 8090,
  [string]$InfraRoot = "$env:USERPROFILE\shop-local-infra"
)

$ErrorActionPreference = 'Stop'
$repos = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logs  = Join-Path $InfraRoot 'svc-logs'

# nazwa | port | env specyficzne dla serwisu
$services = @(
  @{ n='shop-catalog';       p=8081; e=@{ SPRING_DATASOURCE_URL='jdbc:postgresql://localhost:5432/catalog_db'; SHOP_TEST_SUPPORT_ENABLED='true' } },
  @{ n='shop-inventory';     p=8082; e=@{ SPRING_DATASOURCE_URL='jdbc:postgresql://localhost:5432/inventory_db'; SPRING_KAFKA_CONSUMER_GROUP_ID='shop-inventory'; RESERVATION_TTL_SECONDS='600'; SHOP_TEST_SUPPORT_ENABLED='true' } },
  @{ n='shop-order';         p=8083; e=@{ SPRING_DATASOURCE_URL='jdbc:postgresql://localhost:5432/order_db'; SPRING_KAFKA_CONSUMER_GROUP_ID='shop-order'; SAGA_PAYMENT_TIMEOUT_SECONDS='30'; CATALOG_SERVICE_URI='http://localhost:8081' } },
  # PAYMENT_FAILURE_RATE=0.0 jak w helm/values.yaml (preprod): odrzucenia daje wyłącznie
  # deterministyczny hook kwoty `x.66`. Przy losowych 0.15 scenariusz happy path z
  # shop-acceptance-tests padał średnio co siódme uruchomienie.
  @{ n='shop-payment';       p=8084; e=@{ SPRING_DATASOURCE_URL='jdbc:postgresql://localhost:5432/payment_db'; SPRING_KAFKA_CONSUMER_GROUP_ID='shop-payment'; PAYMENT_FAILURE_RATE='0.0'; PAYMENT_LATENCY_MS='200' } },
  @{ n='shop-notification';  p=8085; e=@{ SPRING_DATASOURCE_URL='jdbc:postgresql://localhost:5432/notification_db'; SPRING_KAFKA_CONSUMER_GROUP_ID='shop-notification' } },
  @{ n='shop-token-metrics'; p=8088; e=@{} }
)

function Log($m) { Write-Host ("{0}  {1}" -f (Get-Date -Format HH:mm:ss), $m) -ForegroundColor Cyan }

# Narzędzia natywne (psql, subst, skrypty .bat Kafki) piszą zwykłe komunikaty na stderr —
# choćby `NOTE: Picked up JDK_JAVA_OPTIONS` z każdego launchera Javy. Przy 'Stop'
# PowerShell 5.1 zamienia taką linię w błąd kończący i przerywa skrypt.
function Invoke-Native([scriptblock]$Block) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Block } finally { $ErrorActionPreference = $prev }
}

# ── stop ─────────────────────────────────────────────────────────────────────
if ($Stop) {
  Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
    Where-Object { $_.CommandLine -match 'shop-\w+(-\w+)?-0\.0\.1-SNAPSHOT\.jar|kafka\.Kafka' } |
    ForEach-Object { Log "stop java PID $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force }
  if (Test-Path "$InfraRoot\Redis-x64-5.0.14.1\redis-cli.exe") {
    Invoke-Native { & "$InfraRoot\Redis-x64-5.0.14.1\redis-cli.exe" -p 6379 shutdown nosave 2>&1 | Out-Null }
  }
  if (Test-Path "$InfraRoot\pgsql\bin\pg_ctl.exe") {
    Invoke-Native { & "$InfraRoot\pgsql\bin\pg_ctl.exe" -D "$InfraRoot\pgdata" stop -m fast 2>&1 | Out-Null }
  }
  Log 'zatrzymane'
  return
}

New-Item -ItemType Directory -Force -Path $logs | Out-Null

# ── infrastruktura: Postgres + Redis + Kafka ─────────────────────────────────
if (-not $SkipInfra) {
  $ProgressPreference = 'SilentlyContinue'
  New-Item -ItemType Directory -Force -Path "$InfraRoot\dl" | Out-Null

  $downloads = @(
    @{ u='https://archive.apache.org/dist/kafka/4.0.0/kafka_2.13-4.0.0.tgz'; f='kafka.tgz' },
    @{ u='https://github.com/tporadowski/redis/releases/download/v5.0.14.1/Redis-x64-5.0.14.1.zip'; f='redis.zip' },
    @{ u='https://get.enterprisedb.com/postgresql/postgresql-17.6-1-windows-x64-binaries.zip'; f='postgres.zip' }
  )
  foreach ($d in $downloads) {
    $dest = Join-Path "$InfraRoot\dl" $d.f
    if (-not (Test-Path $dest)) { Log "pobieram $($d.f)"; Invoke-WebRequest -Uri $d.u -OutFile $dest -UseBasicParsing -TimeoutSec 900 }
  }
  if (-not (Test-Path "$InfraRoot\kafka_2.13-4.0.0")) { tar -xzf "$InfraRoot\dl\kafka.tgz" -C $InfraRoot }
  if (-not (Test-Path "$InfraRoot\Redis-x64-5.0.14.1")) { Expand-Archive "$InfraRoot\dl\redis.zip" -DestinationPath "$InfraRoot\Redis-x64-5.0.14.1" -Force }
  if (-not (Test-Path "$InfraRoot\pgsql")) { Expand-Archive "$InfraRoot\dl\postgres.zip" -DestinationPath $InfraRoot -Force }

  # --- Postgres (appuser/apppass, bazy z shop-postgres/01-create-databases.sql) ---
  if (-not (Test-Path "$InfraRoot\pgdata\PG_VERSION")) {
    Log 'initdb'
    $pwfile = "$InfraRoot\pgpass.txt"
    Set-Content -Path $pwfile -Value 'apppass' -NoNewline -Encoding ascii
    Invoke-Native { & "$InfraRoot\pgsql\bin\initdb.exe" -D "$InfraRoot\pgdata" -U appuser --pwfile=$pwfile -E UTF8 --locale=C 2>&1 | Out-Null }
    Remove-Item $pwfile -Force
  }
  if (-not (Get-Process postgres -ErrorAction SilentlyContinue)) {
    Log 'start postgres :5432'
    Start-Process -FilePath "$InfraRoot\pgsql\bin\postgres.exe" `
      -ArgumentList '-D', "$InfraRoot\pgdata", '-p', '5432', '-c', 'listen_addresses=127.0.0.1' `
      -RedirectStandardOutput "$logs\postgres.log" -RedirectStandardError "$logs\postgres.err.log" -WindowStyle Hidden
  }
  # Stały sleep bywał za krótki („the database system is starting up") i bazy się nie tworzyły.
  $deadline = (Get-Date).AddSeconds(60)
  do {
    Start-Sleep -Seconds 1
    Invoke-Native { & "$InfraRoot\pgsql\bin\pg_isready.exe" -h 127.0.0.1 -p 5432 2>&1 | Out-Null }
  } until ($LASTEXITCODE -eq 0 -or (Get-Date) -gt $deadline)
  if ($LASTEXITCODE -ne 0) { throw "postgres nie przyjmuje polaczen po 60 s - patrz $logs\postgres.err.log" }
  $env:PGPASSWORD = 'apppass'
  $existing = Invoke-Native { & "$InfraRoot\pgsql\bin\psql.exe" -h 127.0.0.1 -U appuser -d postgres -tAc "select 1 from pg_database where datname='catalog_db'" }
  if (-not $existing) {
    Log 'tworzę bazy per serwis'
    Invoke-Native { & "$InfraRoot\pgsql\bin\psql.exe" -h 127.0.0.1 -U appuser -d postgres -f "$repos\shop-postgres\01-create-databases.sql" 2>&1 | Out-Null }
  }

  # --- Redis --------------------------------------------------------------
  # UWAGA: Redis musi stać pod ścieżką BEZ sekwencji `\u`. Spring Data Redis parsuje
  # wyjście INFO jako java.util.Properties, a `C:\users\...` to dla niego niepoprawny
  # escape unicode -> „Malformed \uxxxx encoding" i shop-inventory wstaje jako DOWN.
  # Dlatego mapujemy katalog na literę dysku (S:).
  Invoke-Native { subst S: /D 2>&1 | Out-Null; subst S: "$InfraRoot\Redis-x64-5.0.14.1" }
  $conf = (Get-Content "$repos\shop-redis\redis.conf" -Raw) + "`ndir S:/data`nbind 127.0.0.1`nport 6379`n"
  [System.IO.File]::WriteAllText('S:\redis.conf', $conf, (New-Object System.Text.UTF8Encoding($false)))
  New-Item -ItemType Directory -Force -Path 'S:\data' | Out-Null
  if (-not (Get-Process redis-server -ErrorAction SilentlyContinue)) {
    Log 'start redis :6379'
    Start-Process -FilePath 'S:\redis-server.exe' -ArgumentList 'S:\redis.conf' -WorkingDirectory 'S:\' `
      -RedirectStandardOutput "$logs\redis.log" -RedirectStandardError "$logs\redis.err.log" -WindowStyle Hidden
    Start-Sleep -Seconds 3
  }

  # --- Kafka (KRaft) ------------------------------------------------------
  # Tak samo jak Redis, ale z innego powodu: skrypty .bat Kafki budują classpath
  # dłuższy niż limit 8191 znaków („The input line is too long"), a
  # kafka-server-start.bat woła `wmic`, usunięty w Windows 11 24H2. Dysk K: skraca
  # classpath, a broker startujemy wprost z `java -cp`.
  Invoke-Native { subst K: /D 2>&1 | Out-Null; subst K: "$InfraRoot\kafka_2.13-4.0.0" }
  $props = @"
node.id=1
process.roles=broker,controller
listeners=PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
advertised.listeners=PLAINTEXT://localhost:9092
listener.security.protocol.map=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
inter.broker.listener.name=PLAINTEXT
controller.listener.names=CONTROLLER
controller.quorum.voters=1@localhost:9093
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
group.initial.rebalance.delay.ms=0
auto.create.topics.enable=false
num.partitions=6
log.dirs=$($InfraRoot -replace '\\','/')/kafka-data
"@
  [System.IO.File]::WriteAllText("$InfraRoot\kafka-server.properties", $props, (New-Object System.Text.UTF8Encoding($false)))
  $kafkaRunning = Get-CimInstance Win32_Process -Filter "Name='java.exe'" | Where-Object { $_.CommandLine -match 'kafka\.Kafka' }
  if (-not $kafkaRunning) {
    # Kafka nie wspiera Windowsa: na danych z poprzedniej sesji broker obcina segmenty,
    # nie moze przemianowac zmapowanych w pamieci plikow .timeindex ("being used by another
    # process"), oznacza log dir jako failed i gasnie - serwisy wisza wtedy z sagami w PENDING.
    # Sciezka awaryjna nie potrzebuje historii zdarzen, wiec zawsze startujemy z czystym logiem.
    Remove-Item -Recurse -Force "$InfraRoot\kafka-data" -ErrorAction SilentlyContinue
  }
  # CLUSTER_ID jak w docker-compose.yml
  Invoke-Native { & 'K:\bin\windows\kafka-storage.bat' format -t '5L6g3nShT-eMCtK--X86sw' -c "$InfraRoot\kafka-server.properties" --ignore-formatted 2>&1 | Out-Null }
  if (-not $kafkaRunning) {
    Log 'start kafka :9092'
    $kafkaArgs = @('-Xmx1G','-Xms1G','-Dlog4j2.configurationFile=K:\config\log4j2.yaml',"-Dkafka.logs.dir=$InfraRoot\kafka-logs",'-cp','K:\libs\*','kafka.Kafka',"$InfraRoot\kafka-server.properties")
    Start-Process -FilePath 'java.exe' -ArgumentList $kafkaArgs `
      -RedirectStandardOutput "$logs\kafka.log" -RedirectStandardError "$logs\kafka.err.log" -WindowStyle Hidden
    Start-Sleep -Seconds 25
  }
  # Tematy jak w shop-kafka-init z compose.
  foreach ($t in @(@('order-events',6),@('inventory-events',6),@('payment-events',6),
                   @('order-events.DLT',1),@('inventory-events.DLT',1),@('payment-events.DLT',1))) {
    Invoke-Native { & 'K:\bin\windows\kafka-topics.bat' --bootstrap-server localhost:9092 --create --if-not-exists `
      --topic $t[0] --partitions $t[1] --replication-factor 1 2>&1 | Out-Null }
  }
  Log 'infrastruktura gotowa'
}

# ── serwisy ──────────────────────────────────────────────────────────────────
$all = $services + @(@{ n='shop-gateway'; p=$GatewayPort; e=@{
  CATALOG_SERVICE_URI='http://localhost:8081'
  ORDER_SERVICE_URI='http://localhost:8083'
  INVENTORY_SERVICE_URI='http://localhost:8082' } })

foreach ($s in $all) {
  $jar = Join-Path $repos "$($s.n)\build\libs\$($s.n)-0.0.1-SNAPSHOT.jar"
  if (-not (Test-Path $jar)) {
    Log "buduję $($s.n)"
    Push-Location (Join-Path $repos $s.n)
    & .\gradlew.bat --no-daemon bootJar | Out-Null
    Pop-Location
  }
  $envVars = @{
    SERVER_PORT = "$($s.p)"; SPRING_DATASOURCE_USERNAME = 'appuser'; SPRING_DATASOURCE_PASSWORD = 'apppass'
    SPRING_KAFKA_BOOTSTRAP_SERVERS = 'localhost:9092'; SPRING_DATA_REDIS_HOST = 'localhost'; SPRING_DATA_REDIS_PORT = '6379'
  }
  foreach ($k in $s.e.Keys) { $envVars[$k] = $s.e[$k] }
  foreach ($k in $envVars.Keys) { Set-Item -Path "Env:$k" -Value $envVars[$k] }
  Start-Process -FilePath 'java.exe' -ArgumentList '-jar', $jar `
    -RedirectStandardOutput "$logs\$($s.n).log" -RedirectStandardError "$logs\$($s.n).err.log" -WindowStyle Hidden
  foreach ($k in $envVars.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
  Log ("start {0,-20} :{1}" -f $s.n, $s.p)
}

Write-Host ''
Log "bramka:  http://localhost:$GatewayPort/api/products"
Log "logi:    $logs"
Log "UI:      cd ..\shop-ui; npx vite --config vite.config.native.mjs   (proxy -> :$GatewayPort)"
Log "testy:   `$env:SHOP_GATEWAY_URL='http://localhost:$GatewayPort'; cd ..\shop-acceptance-tests; .\gradlew.bat test"
