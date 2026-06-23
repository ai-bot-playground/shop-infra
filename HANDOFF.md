# Handoff — implementacja v0.0.1 (branch `develop_v_0.0.1`)

Stan po autonomicznej implementacji. Cała praca jest na branchu **`develop_v_0.0.1`**
w każdym repo (nic nie poszło do `main`).

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

> Ważne: zweryfikowałem **kompilację** testów (`gradle testClasses`). Uruchomienie
> testów (`gradle test`) wymaga Testcontainers ↔ podman, czyli Twojego środowiska —
> patrz niżej.

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

1. **Potwierdzić runtime-green testów komponentowych** — odpal `.\gradlew.bat test`
   w: `shop-catalog`, `shop-inventory`, `shop-order`, `shop-payment`,
   `shop-notification` (Testcontainers ↔ podman jw.). Ja potwierdziłem tylko kompilację.

2. **E2E na preprod** (`shop-acceptance-tests`):
   - przebuduj obrazy i wdróż na `kind-preprod` (Helm) z włączonym test-support:
     w values/ConfigMap ustaw `SHOP_TEST_SUPPORT_ENABLED=true` dla **shop-catalog**
     i **shop-inventory** (potrzebne do provisioningu danych przez testy),
   - `kubectl --context kind-preprod -n shop port-forward svc/shop-gateway 8080:8080`,
   - w `shop-acceptance-tests`: `.\run-local.ps1` (happy + out-of-stock; payment-decline
     działa dzięki produktowi w cenie `x.66`).

3. **Merge `develop_v_0.0.1` → `main`** per serwis, gdy E2E zielone (na razie nic nie
   mergowałem do main — zgodnie z bramką jakości).

4. **(później) self-hosted runner** + branch protection na `main`, by E2E był
   wymaganym checkiem PR (workflow `shop-acceptance-tests/.github/workflows/acceptance.yml`
   gotowy — wystarczy zmienić `runs-on` na `[self-hosted]` i podłączyć w repo serwisów).

## Czego NIE zrobiłem (wymaga Twojej decyzji/środowiska)
- Uruchomienia testów i E2E (Twój podman/kind) — jw.
- Wykonawczego harnessu UI (cucumber-js + Playwright) — wymaga przeglądarki i żywego
  stacku; ścieżkę zakupu i tak pokrywa `shop-acceptance-tests` przez API. Plik
  `shop-ui/features/shopping-journey.feature` zostaje jako spec.
