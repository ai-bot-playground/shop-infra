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

Czysty restart (usuwa wolumeny z danymi): `podman compose down -v && podman compose up --build`.

Skalowanie: `podman compose up --scale shop-inventory=3`.

Serwisy backendowe nasłuchują na `:8080` wewnątrz sieci `backend` — ruch publiczny idzie przez `shop-gateway`.

### Mapa portów

| Element | URL | Środowisko |
|---|---|---|
| shop-ui | <http://localhost:3000> | podman compose |
| shop-ui | <http://localhost:3001> | kind-preprod (port-forward-ui.ps1) |
| kafka-ui | <http://localhost:8081> | podman compose |
| shop-qa-ui | <http://localhost:8501> | lokalnie (`streamlit run app.py`) |
| Grafana — LLM token dashboard | <http://localhost:3000> | kind-preprod (`kubectl port-forward svc/grafana 3000:3000`) |

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

**E2E:** 3/3 scenariusze (happy path, out of stock, payment declined). `shop-ui` nie jest bramkowany suitem E2E — jego spec to `shop-ui/features/shopping-journey.feature`.

## Testy komponentowe (lokalnie)

Wymagane: Podman Desktop z włączoną „Docker compatibility".

```powershell
cd shop-catalog    # lub dowolny serwis
.\gradlew.bat test
# Jeśli Ryuk sprawia problemy:
$env:TESTCONTAINERS_RYUK_DISABLED = "true"; .\gradlew.bat test
```

## Preprod (kind) i bramka CI

PR do `main` jest bramkowany pełnym E2E na lokalnym klastrze `kind-preprod`. Gate działa na maszynie dewelopera. Kolejność startu: **podman → kind → runner**.

```powershell
# 1) podman machine (Docker compatibility ON — wymagane przez Testcontainers)
podman machine start

# 2) klaster kind
$env:KIND_EXPERIMENTAL_PROVIDER = "podman"
podman start preprod-control-plane
kubectl --context kind-preprod get nodes        # STATUS = Ready

# 3) deploy stacku (Helm)
helm upgrade --install shop ./helm --kube-context kind-preprod -n shop --create-namespace `
  -f ./helm/values.yaml -f ./helm/values-preprod.yaml --timeout 6m

# 4) runnery (jeden per repo serwisowe)
.\register-preprod-runners.ps1 -Start
```


Skrypty pomocnicze: `deploy-preprod.ps1`, `register-preprod-runners.ps1`, `port-forward-ui.ps1`.


### Uruchomienie / zatrzymanie klastra (bez wyłączania podmana)

Ponowne uruchomienie: `podman start preprod-control-plane`, następnie `.\deploy-preprod.ps1`.

```powershell
# undeploy aplikacji
helm uninstall shop --kube-context kind-preprod -n shop

# zatrzymaj kontener kind (podman i podman compose dalej działają)
podman stop preprod-control-plane
```


**Jak działa gate:** `pr-to-main.yml` (`on: pull_request`) → check `preprod-gate / gate` na runnerze `[self-hosted, <svc>]`. Mutex `Global\shop-preprod-gate` serializuje równoległe PR. Checkout 3 repo (kandydat, `shop-infra`, `shop-acceptance-tests`) → `podman build` → `kind load` → `helm upgrade` (baseline) → `kubectl set image` + `rollout status` → port-forward + `./gradlew test`. Zielone = PR odblokowany.

Repozytoria z runnerami: `shop-gateway`, `shop-catalog`, `shop-inventory`, `shop-order`, `shop-payment`, `shop-notification`, `shop-token-metrics`.

### Port-forward UI (kind-preprod)

```powershell
.\port-forward-ui.ps1    # shop-ui (3001) + shop-token-metrics (8088) w jednym oknie
# Grafana: kubectl --context kind-preprod -n shop port-forward svc/grafana 3000:3000
```

`shop-qa-ui` działa lokalnie (nie w klastrze): `cd ../shop-qa-ui; streamlit run app.py --server.port 8501`.
