# Handoff — implementacja v0.0.1 (branch `develop_v_0.0.1`)

> **Aktualizacja (2026-06-30):** stack jest już zmergowany do **`main`** w każdym
> repo. Bramka CI buduje i wdraża na kind-preprod **zawsze z `main`**: refy
> `pr-to-main.yml` (`gate.yml@main`) oraz oba `actions/checkout` w `gate.yml`
> (`ref: main` dla shop-infra i shop-acceptance-tests) wskazują `main`. Poniższy
> opis to historyczny stan z czasu implementacji v0.0.1.

Stan po autonomicznej implementacji. Cała praca powstała na branchu
**`develop_v_0.0.1`** w każdym repo (a następnie została zmergowana do `main`).

## Co zrobione (zaimplementowane + zweryfikowane)

| Serwis | Zakres | Weryfikacja |
|---|---|---|
| shop-catalog | REST (`/products`, `/{id}`, `/search`, PagedModel) + JPA + Flyway(seed) + Caffeine cache + test-support `POST/DELETE /products` | compile-green |
| shop-inventory | atomowa rezerwacja Redis (Lua) + JPA źródło prawdy + outbox + idempotencja + Kafka consumer/publisher + `GET /inventory/{id}` + test-support `PUT/DELETE` | compile-green |
| shop-order | REST `POST/GET /orders` + saga (maszyna stanów) + Kafka (inventory/payment) + outbox multi-topic + idempotencja + timeout-scanner + CatalogClient | compile-green |
| shop-payment | mock PSP (failure-rate + deterministyczny hook `x.66`) + idempotencja po orderId + outbox + Kafka | compile-green |
| shop-notification | konsumpcja terminalnych Order* + idempotentny send (`sent_notifications`) | compile-green |
| shop-ui | lista produktów + zakup (Idempotency-Key) + status na żywo (polling) | vite build-green |

Każdy serwis (poza ui) ma testy **Cucumber + Testcontainers** (Postgres/Redis; Kafkę
weryfikuje dopiero E2E). Stack: Spring Boot 4.0.7 / Java 25 / Gradle 9.6.
Dodano **wrapper Gradle** do każdego serwisu (`./gradlew` bez instalacji gradle).

> **Status testów: wszystkie 5 serwisów `gradlew test` przechodzą na ZIELONO**
> (Testcontainers ↔ podman, Docker compatibility). Po drodze naprawiono dwa realne
> błędy: Flyway na Boot 4 (potrzebne `spring-boot-starter-flyway` +
> `flyway-database-postgresql`) oraz escape `/` w wyrażeniach Cucumber (order).

## Jak uruchomić testy komponentowe lokalnie

Testcontainers potrzebuje API Dockera. W **Podman Desktop** włącz „Docker
compatibility" (udostępnia `\\.\pipe\docker_engine`), wtedy:

```powershell
cd shop-catalog        # albo dowolny serwis
.\gradlew.bat test
```

Gdyby Ryuk (resource reaper) sprawiał problemy na podmanie:
```powershell
$env:TESTCONTAINERS_RYUK_DISABLED = "true"; .\gradlew.bat test
```

## ✅ POTRZEBNE OD CIEBIE (lista, którą miałeś sprawdzić po powrocie)

1. ✅ **ZROBIONE — runtime-green testów komponentowych**: wszystkie 5 serwisów
   `.\gradlew.bat test` przechodzą (uruchomione po włączeniu Docker compatibility).

2. ✅ **ZROBIONE — E2E na preprod ZIELONE (3/3 scenariusze, 12/12 kroków)**.
   Cały stos (Postgres/Redis/Kafka + 6 serwisów) wdrożony w klastrze `kind-preprod`
   i przetestowany end-to-end przez `shop-acceptance-tests`:
   - Happy path → `CONFIRMED`, stock 5→3
   - Out of stock → `REJECTED`, stock bez zmian
   - Payment declined (kwota `6.66`) → `CANCELLED`, rezerwacja zwolniona

   **Runbook (odtworzenie):**
   ```powershell
   # 1) build obrazów (multi-stage, gradle w kontenerze)
   foreach ($s in "shop-gateway","shop-catalog","shop-inventory","shop-order",
                   "shop-payment","shop-notification","shop-ui") {
     podman build -t "localhost/$s:0.0.1" "../$s"
   }
   # 2) load do klastra (provider podman)
   $env:KIND_EXPERIMENTAL_PROVIDER="podman"
   podman save -o imgs.tar localhost/shop-gateway:0.0.1 localhost/shop-catalog:0.0.1 `
     localhost/shop-inventory:0.0.1 localhost/shop-order:0.0.1 localhost/shop-payment:0.0.1 `
     localhost/shop-notification:0.0.1 localhost/shop-ui:0.0.1
   kind load image-archive imgs.tar --name preprod
   # 3) deploy (in-cluster infra + test-support dla catalog/inventory)
   helm upgrade --install shop ./helm --kube-context kind-preprod -n shop --create-namespace `
     -f ./helm/values.yaml -f ./helm/values-preprod.yaml --timeout 6m
   # 4) E2E
   cd ../shop-acceptance-tests; .\run-local.ps1
   ```

   **Bugi Boot 4 / Spring Cloud 2025.1, które E2E wyłapało (a testy komponentowe nie):**
   - Kafka: na Boot 4 sam `org.springframework.kafka:spring-kafka` NIE włącza
     `KafkaAutoConfiguration` → brak `KafkaTemplate`/`@KafkaListener`. Fix:
     `spring-boot-starter-kafka` (order/payment/inventory/notification). *(maskowane
     w testach: `outbox.enabled=false`, listenery wołane bezpośrednio).*
   - Gateway: Spring Cloud Gateway 2025.1 czyta trasy pod
     `spring.cloud.gateway.server.webflux.routes` (stary `spring.cloud.gateway.routes`
     ignorowany → 0 tras → 404).
   - Jackson 3: `HttpCatalogClient` deserializował do Jackson-2 `JsonNode` przez RestClient
     (Boot 4 = Jackson 3) → `InvalidDefinitionException`. Fix: deserializacja do `Map`.
     *(maskowane w testach: order używał zaślepki `CatalogClient`).*
   - Kafka probe: `kafka-broker-api-versions.sh` jako exec-probe forkuje JVM (~3-5s) i
     przekracza domyślny `timeoutSeconds=1` → crashloop. Fix: `tcpSocket` na 9092.
   - Scenario data: payment-decline liczył kwotę `6.66×2=13.32` (nie trafiał w hook
     `cents%100==66`). Fix: zamówienie 1 szt. → kwota `6.66`.

3. **Merge `develop_v_0.0.1` → `main`** per serwis — **teraz odblokowane** (E2E zielone).
   Nadal Twoja decyzja; nic nie zmergowałem do `main` (bramka jakości).

4. **(później) self-hosted runner** + branch protection na `main`, by E2E był
   wymaganym checkiem PR (workflow `shop-acceptance-tests/.github/workflows/acceptance.yml`
   gotowy — wystarczy zmienić `runs-on` na `[self-hosted]` i podłączyć w repo serwisów).

## Czego NIE zrobiłem (wymaga Twojej decyzji/środowiska)
- Uruchomienia testów i E2E (Twój podman/kind) — jw.
- Wykonawczego harnessu UI (cucumber-js + Playwright) — wymaga przeglądarki i żywego
  stacku; ścieżkę zakupu i tak pokrywa `shop-acceptance-tests` przez API. Plik
  `shop-ui/features/shopping-journey.feature` zostaje jako spec.
