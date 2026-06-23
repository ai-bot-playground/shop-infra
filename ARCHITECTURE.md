# Architektura — system sklepu (flash sale)

Diagramy architektury całego rozwiązania. Wszystkie wykresy są w składni
[Mermaid](https://mermaid.js.org) — renderują się natywnie na GitHubie i w wielu
edytorach Markdown. Opis tekstowy i mapy portów: zobacz [README.md](README.md).

Spis:
1. [Kontekst systemu](#1-kontekst-systemu)
2. [Komponenty i deployment](#2-komponenty-i-deployment)
3. [Przepływ zdarzeń Kafki](#3-przepływ-zdarzeń-kafki)
4. [Saga zakupu — ścieżka udana](#4-saga-zakupu--ścieżka-udana)
5. [Saga zakupu — kompensacja](#5-saga-zakupu--kompensacja)
6. [Maszyna stanów zamówienia](#6-maszyna-stanów-zamówienia)

---

## 1. Kontekst systemu

Kto i co styka się z systemem. W demie zależności zewnętrzne są zamockowane.

```mermaid
graph TB
    buyer(("Kupujący<br/>(przeglądarka)"))
    subgraph sys["System sklepu"]
        shop["shop-ui · shop-gateway · shop-catalog<br/>shop-order · shop-inventory<br/>shop-payment · shop-notification<br/>shop-kafka · PostgreSQL · Redis"]
    end
    psp["Operator płatności<br/>(prod: Stripe / PayU,<br/>demo: mock)"]
    mail["Kanał powiadomień<br/>(prod: SMTP / SMS,<br/>demo: MailHog / log)"]

    buyer -->|"HTTPS"| sys
    sys -->|"rozliczenie"| psp
    sys -->|"e-mail / SMS"| mail
```

---

## 2. Komponenty i deployment

Kontenery uruchamiane przez `docker-compose.yml`, podział na sieci `frontend` i
`backend`. Tylko `shop-ui`, `shop-gateway` i narzędzia są wystawione na hosta —
serwisy backendu nasłuchują na `:8080` wyłącznie wewnątrz sieci `backend`.

```mermaid
graph TB
    buyer(("Kupujący"))

    subgraph host["Host (Docker)"]
        UI["shop-ui<br/>React + nginx · :3000"]

        subgraph backend["sieć backend"]
            GW["shop-gateway<br/>Spring Cloud Gateway · :8080"]
            CAT["shop-catalog · :8080"]
            ORD["shop-order · :8080"]
            INV["shop-inventory · :8080"]
            PAY["shop-payment · :8080"]
            NOT["shop-notification · :8080"]
            K[["shop-kafka (KRaft)<br/>:9092 / host :29092"]]
            KUI["kafka-ui · :8081"]
            PG[("PostgreSQL · :5432<br/>catalog / inventory / order /<br/>payment / notification _db")]
            RD[("Redis · :6379")]
        end
    end

    buyer -->|":3000"| UI
    UI -->|"proxy /api → :8080"| GW

    GW -->|"/api/products"| CAT
    GW -->|"/api/orders"| ORD
    GW -->|"/api/inventory"| INV
    GW -->|"rate limit"| RD

    CAT --> PG
    ORD --> PG
    INV --> PG
    PAY --> PG
    NOT --> PG
    INV -->|"stock / rezerwacje"| RD
    CAT -.->|"cache"| RD

    ORD <--> K
    INV <--> K
    PAY <--> K
    K --> NOT
    KUI -.-> K
```

---

## 3. Przepływ zdarzeń Kafki

Kto produkuje, a kto konsumuje poszczególne tematy. Klucz partycji w nawiasie —
`productId` na `inventory-events` gwarantuje kolejność zdarzeń per produkt.

```mermaid
graph LR
    ORD["shop-order"]
    INV["shop-inventory"]
    PAY["shop-payment"]
    NOT["shop-notification"]

    OE(["order-events<br/>6p · orderId"])
    IE(["inventory-events<br/>6p · productId"])
    PE(["payment-events<br/>6p · orderId"])

    ORD -->|"OrderCreated, ReleaseStock,<br/>OrderConfirmed/Cancelled/Rejected"| OE
    OE -->|"OrderCreated, ReleaseStock"| INV
    OE -->|"OrderConfirmed/Cancelled/Rejected"| NOT

    INV -->|"StockReserved/Failed/Released"| IE
    IE -->|"StockReserved/Failed"| ORD

    ORD -->|"PaymentRequested"| PE
    PE -->|"PaymentRequested"| PAY
    PAY -->|"PaymentCompleted/Failed"| PE
    PE -->|"PaymentCompleted/Failed"| ORD
```

> **Uwaga:** `shop-notification` **nie ma własnego tematu** — konsumuje terminalne
> zdarzenia `OrderConfirmed` / `OrderCancelled` / `OrderRejected` wprost z
> `order-events` (własna grupa konsumenta `shop-notification`). To zwykła
> subskrypcja zdarzeń domenowych, dzięki której `shop-order` pozostaje niezależny
> od powiadomień. Gdyby trzeba było odseparować ruch powiadomień (własna
> retencja/partycje, bogatsze komendy powiadomień), można dołożyć dedykowany temat
> wraz z producentem.
>
> Konsumpcja jest *at-least-once* → każdy konsument musi być **idempotentny**
> (`processed_events` / `sent_notifications`). Po wyczerpaniu prób zdarzenie ląduje
> na `<temat>.DLT`.

---

## 4. Saga zakupu — ścieżka udana

Orkiestracja przez `shop-order`. Odpowiedź dla klienta wraca od razu (`202`),
a dalsze kroki dzieją się asynchronicznie przez zdarzenia (strzałki przerywane).

```mermaid
sequenceDiagram
    autonumber
    actor U as Kupujący
    participant GW as shop-gateway
    participant ORD as shop-order
    participant INV as shop-inventory
    participant RD as Redis
    participant PAY as shop-payment
    participant NOT as shop-notification

    U->>GW: POST /api/orders (Idempotency-Key)
    GW->>ORD: POST /orders
    ORD->>ORD: zapis PENDING + OrderCreated → outbox
    ORD-->>U: 202 Accepted (orderId)
    ORD-)INV: OrderCreated
    INV->>RD: Lua: check + DECRBY stock + SET reservation (TTL)
    RD-->>INV: OK (zarezerwowano)
    INV-)ORD: StockReserved
    ORD->>ORD: stan → RESERVED
    ORD-)PAY: PaymentRequested
    PAY->>PAY: rozliczenie (mock)
    PAY-)ORD: PaymentCompleted
    ORD->>ORD: stan → CONFIRMED
    ORD-)NOT: OrderConfirmed
    NOT-->>U: powiadomienie „zakup udany”
    Note over U,GW: shop-ui śledzi status przez GET /api/orders/{id} (SSE / polling)
```

---

## 5. Saga zakupu — kompensacja

Płatność odrzucona (lub timeout sagi) → `shop-order` cofa rezerwację komendą
`ReleaseStock`. Niezależny bezpiecznik: TTL rezerwacji w Redis.

```mermaid
sequenceDiagram
    autonumber
    participant ORD as shop-order
    participant INV as shop-inventory
    participant RD as Redis
    participant PAY as shop-payment
    participant NOT as shop-notification

    Note over ORD,PAY: stan RESERVED — oczekiwanie na wynik płatności
    PAY-)ORD: PaymentFailed
    ORD->>ORD: stan → CANCELLED
    ORD-)INV: ReleaseStock (komenda kompensująca)
    INV->>RD: INCRBY stock + DEL reservation (idempotentnie)
    INV-)ORD: StockReleased
    ORD-)NOT: OrderCancelled
    NOT-->>NOT: powiadomienie „płatność nieudana”
    Note over INV,RD: Bezpiecznik: jeśli ReleaseStock zaginie,<br/>rezerwacja i tak wygaśnie po TTL
```

Wariant **REJECTED** (brak towaru) nie wymaga kompensacji — to *forward recovery*:
`StockReservationFailed` → `shop-order` ustawia `REJECTED` i emituje `OrderRejected`
(brak rezerwacji do cofnięcia).

---

## 6. Maszyna stanów zamówienia

Stan i krok sagi są utrwalane w `order_db` (`saga_state`), więc po restarcie
serwis wznawia od miejsca przerwania.

```mermaid
stateDiagram-v2
    [*] --> PENDING: POST /orders
    PENDING --> RESERVED: StockReserved
    PENDING --> REJECTED: StockReservationFailed
    RESERVED --> CONFIRMED: PaymentCompleted
    RESERVED --> CANCELLED: PaymentFailed / timeout
    CONFIRMED --> [*]
    REJECTED --> [*]
    CANCELLED --> [*]

    note right of CANCELLED
        emisja ReleaseStock (kompensacja)
        + OrderCancelled
    end note
    note right of REJECTED
        forward recovery — bez kompensacji
        + OrderRejected
    end note
```
