# shop-infra

Dokumentacja, diagramy, `docker-compose.yml` i Helm chart dla systemu sklepu (scenariusz *flash sale*).
To **nie jest serwis** — to centralny punkt orientacyjny całego playground.

Wszystkie repozytoria klonuj jako **siostrzane katalogi** w `ai-bot-playground/`.

## Repozytoria

| Repo | Rola |
|---|---|
| `shop-infra` | dokumentacja, diagramy, `docker-compose.yml`, Helm chart, skrypty preprod |
| `shop-gateway` | API Gateway (Spring Cloud Gateway) |
| `shop-catalog` | katalog produktów (read-heavy, cache Caffeine) |
| `shop-inventory` | magazyn i rezerwacje (atomowa rezerwacja Redis + Lua) |
| `shop-order` | zamówienia — orkiestrator sagi |
| `shop-payment` | płatności (mock PSP) |
| `shop-notification` | powiadomienia (konsument terminalnych zdarzeń) |
| `shop-kafka` | infrastruktura Kafki + kontrakty zdarzeń |
| `shop-postgres` | skrypt init baz (`database-per-service`) |
| `shop-redis` | konfiguracja Redis (stock, locki, cache) |
| `shop-ui` | frontend kupującego (React) |
| `shop-qa-ui` | narzędzie QA (Streamlit + LLM) — poza klastrem |
| `shop-token-metrics` | metryki zużycia tokenów LLM (Spring Boot + Micrometer) |
| `shop-acceptance-tests` | testy E2E (Cucumber + Testcontainers) |

**Stack serwisów:** Spring Boot 4.0.7 / Java 25 / Gradle 9.6. Każdy serwis (poza `shop-ui`) ma testy Cucumber + Testcontainers.

## Uruchomienie lokalne (podman compose)

Wymaga: Podman Desktop lub Docker Desktop z włączoną „Docker compatibility".

```powershell
# pierwsze uruchomienie lub po zmianie kodu
cd shop-infra
podman compose up --build

# kolejne starty (bez przebudowy)
podman compose up -d
```

Klucz OpenRouter (wymagany przez `shop-qa-ui`):

```powershell
$env:OPENROUTER_API_KEY = "sk-or-..."
podman compose up -d
```

Zatrzymanie:

```powershell
podman compose stop      # zatrzymuje kontenery, zachowuje dane
podman compose down      # zatrzymuje i usuwa kontenery (dane w wolumenach nienaruszone)
podman compose down -v   # zatrzymuje + usuwa kontenery i wolumeny (czyste środowisko)
```

Skalowanie: `podman compose up --scale shop-inventory=3`.

Serwisy backendowe nasłuchują na `:8080` wewnątrz sieci `backend` — ruch publiczny idzie przez `shop-gateway`.


### Uruchomienie / zatrzymanie klastra (bez wyłączania podmana)

Ponowne uruchomienie: `.\start-dev.ps1` (patrz „Preprod (kind) i bramka CI") — startuje węzeł i sprawdza całość; pełne wdrożenie od nowa: `.\start-dev.ps1 -Deploy` albo `.\deploy-kubernetes-preprod.ps1 -SkipBuild` (prefiks `.\` wymagany przez PowerShell).

```powershell
# undeploy aplikacji
helm uninstall shop --kube-context kind-preprod -n shop

# zatrzymaj kontener kind (podman i podman compose dalej działają)
podman stop preprod-control-plane
```



### Podman na tej maszynie: DOCKER_HOST i Testcontainers

Trzy rzeczy, ktore trzeba ustawic, zanim `podman compose` albo Testcontainers zadzialaja
z Windowsa. Wszystkie wynikaja z tego, jak WSL laczy sie z hostem — zadna nie wymaga admina.

1. **Porty kontenerow sa osiagalne pod IP maszyny WSL, nie pod `localhost`.**
   `localhostForwarding` na tej maszynie nie dziala (sprawdzone takze z jawnym wpisem
   w `.wslconfig`). `podman ps` pokazuje `0.0.0.0:PORT->...`, z wnetrza maszyny port
   odpowiada, a `127.0.0.1:PORT` z Windowsa — nie. Adres maszyny:

   ```powershell
   $ip = (podman machine ssh -- ip -4 -o addr show eth0 | Select-String '(\d+\.\d+\.\d+\.\d+)/').Matches[0].Groups[1].Value
   ```

2. **Brak `\.\pipe\docker_engine`** — Testcontainers nie znajduje srodowiska Dockera
   („Could not find a valid Docker environment"). Wystaw API podmana po TCP w maszynie:

   ```powershell
   podman machine ssh --username root "nohup podman system service --time=0 tcp://0.0.0.0:2375 >/tmp/pmapi.log 2>&1 &"
   ```

3. **Ryuk (reaper Testcontainers) jest nieosiagalny** — stad `Could not connect to Ryuk`.

Komplet zmiennych do uruchomienia testow komponentowych:

```powershell
$ip = '172.23.113.114'                      # patrz punkt 1 — zmienia sie po restarcie maszyny
$env:DOCKER_HOST                = "tcp://${ip}:2375"
$env:TESTCONTAINERS_HOST_OVERRIDE = $ip
$env:TESTCONTAINERS_RYUK_DISABLED = 'true'
cd ..\shop-catalog; .\gradlew.bat test
```

Uwaga: `podman system service` po TCP jest **nieuwierzytelnione**. Slucha na interfejsie
maszyny WSL (osiagalnym tylko z tego hosta), ale nie zostawiaj go uruchomionego na stale —
konczy sie z `podman machine stop`.

Poniewaz porty ida przez IP maszyny, a nie `localhost`, adresy z „Mapy portow" nizej
czytaj jako `http://<IP-maszyny>:<port>` dopoki `localhostForwarding` nie zacznie dzialac.

### Awaryjnie: uruchomienie BEZ kontenerow (`start-native-no-containers.ps1`)

Gdy `podman machine start` konczy sie bledem

```
Wsl/Service/CreateInstance/CreateVm/HCS/0x80070569
```

(`ERROR_LOGON_TYPE_NOT_GRANTED`), WSL nie tworzy **zadnej** maszyny — sprawdz
`wsl -d Ubuntu -- echo ok`. Padaja wtedy naraz: `podman compose`, kind-preprod
i Testcontainers. Naprawa wymaga admina (prawo „Log on as a service" dla
`NT VIRTUAL MACHINE\Virtual Machines`, zwykle skasowane przez GPO).

Do czasu naprawy caly sklep da sie uruchomic natywnie — serwisy to zwykle procesy
Javy, a Postgres/Redis/Kafka maja buildy na Windows:

```powershell
.\start-native-no-containers.ps1          # pobiera infra, tworzy bazy i tematy, startuje 7 serwisow
.\start-native-no-containers.ps1 -Stop    # zatrzymuje wszystko
```

Skrypt odwzorowuje `docker-compose.yml` 1:1 (te same zmienne srodowiskowe), tylko
nazwy hostow zamienia na `localhost`, a serwisom nadaje osobne porty:
gateway `8090` (przestawialny `-GatewayPort`), catalog `8081`, inventory `8082`,
order `8083`, payment `8084`, notification `8085`, token-metrics `8088`.

Weryfikacja na zywo:

```powershell
$env:SHOP_GATEWAY_URL = 'http://localhost:8090'
cd ..\shop-acceptance-tests; .\gradlew.bat test      # 3 scenariusze E2E
cd ..\shop-ui; npx vite --config vite.config.native.mjs   # UI na :3000
```

Czego to NIE zastepuje: bramki `preprod-gate`, klastra kind i testow komponentowych
na Testcontainers — one nadal wymagaja dzialajacych kontenerow.

## Preprod (kind) i bramka CI

PR do `main` jest bramkowany pełnym E2E na lokalnym klastrze `kind-preprod`. Gate działa na maszynie dewelopera. Kolejność startu: **podman → kind → runner**.

**Po starcie komputera / restarcie maszyny podmana — jedna komenda:**

```powershell
.\start-dev.ps1
```

Idempotentnie, z podsumowaniem `OK`/`UWAGA`/`FAIL` i kodem wyjścia ≠ 0 przy błędzie:

1. maszyna podmana;
2. API podmana `tcp://<IP>:2375` (Testcontainers w bramkach);
3. węzeł kind;
4. kubeconfig i `.env` runnerów przepięte na bieżące IP;
5. gotowość podów;
6. tematy Kafki — gdy ich brak, `helm upgrade`, a hook je odtwarza;
7. runnery `offline` według statusu na GitHubie — działających nie dubluje, także uruchomionych z okna admina;
8. smoke: `shop-acceptance-tests` 3/3.

Klaster trzyma stan między restartami, więc nic nie jest przebudowywane. Opcje: `-Deploy` (+ `-Full`) — wdróż od nowa; `-Compose` — stack docker-compose; `-SkipRunners`, `-SkipSmoke`. Uwaga: runner uruchomiony z okna admina po zmianie IP trzeba zrestartować ręcznie (skrypt to zgłosi) — nie widać jego procesu.

Ręcznie, krok po kroku:

```powershell
# 1) podman machine (Docker compatibility ON — wymagane przez Testcontainers)
podman machine start

# 2) klaster kind
$env:KIND_EXPERIMENTAL_PROVIDER = "podman"
podman start preprod-control-plane              # gdy klastra nie ma: .\create-kind-preprod.ps1
kubectl --context kind-preprod get nodes        # STATUS = Ready

# 3) deploy stacku (Helm)
helm upgrade --install shop ./helm --kube-context kind-preprod -n shop --create-namespace `
  -f ./helm/values.yaml -f ./helm/values-preprod.yaml --timeout 6m

# 4) runnery (jeden per repo serwisowe)
.\register-preprod-runners.ps1 -Start
```


Skrypty pomocnicze: `create-kind-preprod.ps1`, `deploy-kubernetes-preprod.ps1`, `register-preprod-runners.ps1`, `port-forward-ui.ps1`.

**Nowy klaster (`create-kind-preprod.ps1`).** Porty kontenerów nie są tu osiągalne pod `localhost` (patrz „Podman na tej maszynie"), więc domyślny klaster kind jest z Windowsa martwy. Skrypt publikuje API server na interfejsie maszyny WSL, kubeconfig wskazuje `https://<IP-maszyny>:6443` z `tls-server-name=localhost` (SAN, który kind zawsze ma). Po restarcie maszyny (nowe IP): `.\create-kind-preprod.ps1 -RefreshKubeconfig`.

**Runnery i Testcontainers.** Etap komponentowy bramki potrzebuje tych samych zmiennych co lokalne testy — wpisz je do `C:\actions-runner\<svc>\.env` (runner czyta ten plik przy starcie): `DOCKER_HOST`, `TESTCONTAINERS_HOST_OVERRIDE`, `TESTCONTAINERS_RYUK_DISABLED=true`.

### Mapa portów

| Element | URL | Środowisko |
|---|---|---|
| shop-ui | <http://localhost:3000> | podman compose |
| shop-ui | <http://localhost:3001> | kind-preprod (port-forward-ui.ps1) |
| kafka-ui | <http://localhost:8081> | podman compose |
| shop-qa-ui (k8s) | <http://localhost:8501> | kind-preprod (port-forward-ui.ps1) |
| shop-qa-ui (lokalnie) | <http://localhost:8502> | natywnie (`shop-qa-ui/run-local.ps1`), uruchamiany przez `deploy-kubernetes-preprod.ps1` |
| Grafana — LLM token dashboard | <http://localhost:3002> | kind-preprod (`kubectl port-forward svc/grafana 3002:3000`) |

## Architektura

### Komponenty i deployment

Kontenery `docker-compose.yml`, sieci `frontend` / `backend`. Na hosta wystawione tylko `shop-ui`, `shop-gateway` i narzędzia.

```
Kupujący
  → shop-ui             [:3000]
    → shop-gateway      [:8080]  ← publiczny punkt wejścia
        ├── /api/products  → shop-catalog
        ├── /api/orders    → shop-order
        ├── /api/inventory → shop-inventory
        └── rate limit     → Redis

Serwisy backendu (sieć backend, port :8080 — niedostępne z zewnątrz):
  shop-catalog     → PostgreSQL (catalog_db),    Redis (cache)
  shop-inventory   → PostgreSQL (inventory_db),  Redis (stock, rezerwacje Lua)  ↔ Kafka
  shop-order       → PostgreSQL (order_db)                                       ↔ Kafka
  shop-payment     → PostgreSQL (payment_db)                                     ↔ Kafka
  shop-notification → PostgreSQL (notification_db)                               ← Kafka

Narzędzia:
  kafka-ui  [:8081]   — podgląd tematów i consumer lag
  shop-kafka [:29092] — dostęp lokalny z hosta
```

### Bazy danych (`database-per-service`)

| Baza | Kluczowe tabele |
|---|---|
| `catalog_db` | `products`, `categories` |
| `inventory_db` | `products(total_stock, version)`, `reservations`, `outbox`, `processed_events` |
| `order_db` | `orders(idempotency_key UNIQUE)`, `saga_state`, `outbox`, `processed_events` |
| `payment_db` | `payments(idempotency_key UNIQUE)`, `outbox` |
| `notification_db` | `sent_notifications(event_id PK)` |

### Tematy Kafki

| Temat | Partycje | Klucz | Zdarzenia |
|---|---|---|---|
| order-events | 6 | orderId | OrderCreated, OrderConfirmed, OrderCancelled, OrderRejected |
| inventory-events | 6 | productId | StockReserved, StockReservationFailed, StockReleased |
| payment-events | 6 | orderId | PaymentRequested, PaymentCompleted, PaymentFailed |
| `*.DLT` | 1 | — | Dead Letter Topic |

Klucz `productId` na `inventory-events` gwarantuje kolejność per produkt. Konsumpcja jest *at-least-once* → konsumenci muszą być idempotentni (`processed_events` / `sent_notifications`). Po wyczerpaniu prób → `<temat>.DLT`.
`shop-notification` nie ma własnego tematu — konsumuje terminalne zdarzenia bezpośrednio z `order-events` (własna grupa konsumenta).

| Producent | Temat | Konsument | Zdarzenia |
|---|---|---|---|
| shop-order | order-events | shop-inventory | OrderCreated, ReleaseStock |
| shop-order | order-events | shop-notification | OrderConfirmed, OrderCancelled, OrderRejected |
| shop-inventory | inventory-events | shop-order | StockReserved, StockReservationFailed |
| shop-order | payment-events | shop-payment | PaymentRequested |
| shop-payment | payment-events | shop-order | PaymentCompleted, PaymentFailed |

## Saga zakupu

Odpowiedź `202` wraca od razu; kolejne kroki dzieją się asynchronicznie. Stan i krok sagi są utrwalone w `order_db.saga_state` — serwis wznawia po restarcie.

- **Happy path:** `POST /orders` → `OrderCreated` → rezerwacja Redis (Lua: check + DECRBY + SET reservation z TTL) → `StockReserved` → `PaymentRequested` → `PaymentCompleted` → `OrderConfirmed`
- **Kompensacja (płatność odrzucona):** `PaymentFailed` → `CANCELLED` + `ReleaseStock` (INCRBY + DEL reservation, idempotentnie) → stock wraca. Bezpiecznik: TTL rezerwacji w Redis (jeśli `ReleaseStock` zaginie, rezerwacja i tak wygaśnie).
- **Brak towaru:** `StockReservationFailed` → `REJECTED` (forward recovery, bez kompensacji — brak rezerwacji do cofnięcia).

```
POST /orders → PENDING
  PENDING  → RESERVED   (StockReserved)
  PENDING  → REJECTED   (StockReservationFailed) → koniec  [forward recovery, OrderRejected]
  RESERVED → CONFIRMED  (PaymentCompleted)        → koniec
  RESERVED → CANCELLED  (PaymentFailed / timeout) → koniec  [ReleaseStock + OrderCancelled]
```

## Obserwowalność zużycia tokenów LLM

`shop-qa-ui` (Streamlit) woła LLM i raportuje zużycie tokenów do `shop-token-metrics` (Spring Boot + Micrometer → `/actuator/prometheus`). Prometheus scrapuje, Grafana rysuje dashboard *„LLM Token Usage"*.

Liczniki: `llm_tokens_total{type,model,source}`, `llm_requests_total{model,source}`, `llm_cost_usd_total{model,source}`.

## Status implementacji

Wszystko zmergowane do `main`. Zaimplementowane:

| Serwis | Zakres |
|---|---|
| shop-catalog | REST + JPA + Flyway (seed) + Caffeine cache + test-support `POST/DELETE /products` |
| shop-inventory | atomowa rezerwacja Redis (Lua) + JPA + outbox + idempotencja + Kafka |
| shop-order | REST `POST/GET /orders` + saga + Kafka + outbox multi-topic + idempotencja + timeout-scanner |
| shop-payment | mock PSP (failure-rate + hook `cents%100==66`) + idempotencja + outbox + Kafka |
| shop-notification | konsumpcja terminalnych `Order*` + idempotentny send (`sent_notifications`) |
| shop-ui | lista produktów + zakup (Idempotency-Key) + status (polling) |

**E2E:** 3/3 scenariusze (happy path, out of stock, payment declined). `shop-ui` nie wchodzi do cross-service suite'u E2E (jego spec to `shop-ui/features/shopping-journey.feature`), ale ma **własną bramkę preprod** `ui-preprod-gate` (build vite + deploy na kind-preprod + smoke-test) — patrz sekcja „Preprod (kind) i bramka CI".

## Testy komponentowe (lokalnie)

Wymagane: Podman Desktop z włączoną „Docker compatibility".

```powershell
cd shop-catalog    # lub dowolny serwis
.\gradlew.bat test
# Jeśli Ryuk sprawia problemy:
$env:TESTCONTAINERS_RYUK_DISABLED = "true"; .\gradlew.bat test
```

**Jak działa gate (serwisy Java):** `pr-to-main.yml` (`on: pull_request`) → check `preprod-gate / gate` na runnerze `[self-hosted, <svc>]`. Mutex `Global\shop-preprod-gate` serializuje równoległe PR. Checkout 3 repo (kandydat, `shop-infra`, `shop-acceptance-tests`) → `gradlew test` → `podman build` → `kind load` → `helm upgrade` z `--set-string services.<svc>.image` + `rollout status` → port-forward + `./gradlew test` (acceptance). Zielone = PR odblokowany. Czerwone po wdrożeniu = bramka (wciąż pod mutexem) przywraca obraz bazowy, żeby zepsuty kandydat nie został na wspólnym preprod.

**Po merge'u (`promote-preprod.yml` → `shop-acceptance-tests/.github/workflows/promote.yml`):** `push` do `main` odbudowuje obraz bazowy `localhost/<svc>:0.0.1` z `main`, ładuje go do kind i restartuje deployment (ten sam mutex). Każda bramka robi `helm upgrade` z obrazami bazowymi — bez tego kroku następna bramka dowolnego repo cofała zmergowaną zmianę z preprod.

**Podgląd przed merge'em jest ulotny:** kandydat zostaje na preprod tylko do następnej bramki dowolnego repo (ta wdraża bazę + swojego kandydata). Przy kilku PR-ach naraz sprawdzaj zmianę zaraz po zielonej bramce.

**Bramka shop-ui** (frontend, nie-Gradle): własny workflow `ui-preprod-gate / gate` na runnerze `[self-hosted, shop-ui]`. Nie używa reusable `gate.yml` (Java-specyficzny). Kroki: `npm ci` + `vite build` → `podman build` → `kind load` → `helm upgrade` z `--set-string services.shop-ui.image` + `rollout status deployment/shop-ui` → smoke-test (port-forward `svc/shop-ui`, GET `/` = 200 + `#root`). Dzieli ten sam klaster i mutex `Global\shop-preprod-gate` co bramki Java.

Repozytoria z runnerami (`register-preprod-runners.ps1`): `shop-gateway`, `shop-catalog`, `shop-inventory`, `shop-order`, `shop-payment`, `shop-notification`, `shop-token-metrics`, `shop-ui`.

### Port-forward UI (kind-preprod)

```powershell
.\port-forward-ui.ps1    # shop-ui (3001) + shop-token-metrics (8088) w jednym oknie
# Grafana: kubectl --context kind-preprod -n shop port-forward svc/grafana 3000:3000
```

`shop-qa-ui` jest deployowany do klastra (port-forward na **:8501**) i jednocześnie uruchamiany **natywnie** (bez kontenera) na porcie **:8502** przez `deploy-kubernetes-preprod.ps1` via `shop-qa-ui/run-local.ps1`. Natywny tryb umożliwia zapis do lokalnych repozytoriów i `gh pr create` z Windows Credential Manager.
