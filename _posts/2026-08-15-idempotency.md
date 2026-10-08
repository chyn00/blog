---
title: "주문 커밋 뒤 재고 감소까지, Kafka 이벤트의 복구 경계"
date: 2026-08-15 09:00:00 +0900
description: "Redis 재고 선차감에서 시작해 주문, Kafka, 재고 반영까지 직접 연결하며 트랜잭션 경계와 재처리 범위를 확인한 미니 프로젝트 기록입니다."
categories: [engineering]
category_label: "Engineering"
tags: [Kafka, Messaging, MySQL]
topics: [backend]
image: /assets/images/thumb-kafka-first-step-realized.png
mermaid: true
toc_items:
  - id: question
    title: "주문과 재고 사이의 질문"
  - id: transaction
    title: "트랜잭션이란?"
  - id: flow
    title: "커밋 전 기록, 커밋 후 발행"
  - id: recovery
    title: "기록이 있어도 복구되지 않는 구간"
  - id: consumer
    title: "재전달과 재고 차감"
  - id: boundary
    title: "이 흐름의 보장 범위"
  - id: lesson
    title: "Lesson learned"
---

## 주문과 재고 사이의 질문 {#question}

처음에는 Redis에서 재고를 먼저 줄여 동시 주문을 처리하는 문제로 시작했습니다. 하지만 Redis를 쓰는 것만으로 주문부터 재고 반영까지 안전해지는 것은 아니었습니다. 주문 저장, Kafka 발행, 재고 DB 차감을 연결하면서 무엇이 함께 커밋되고, 발행이 끊기면 어디서 다시 시작할지까지 정해야 했습니다.

주문 엔드포인트 하나와 재고 Consumer 하나로 만든 미니 프로젝트입니다. 이 정도 범위라면 일반적인 메시지 큐로도 충분했습니다. 그래도 이전에 Kafka를 써본 경험이 있어 이번에는 Kafka로 흐름을 구성했습니다. 작은 흐름을 핸즈온으로 끝까지 만들어보니 각 단계에서 확인해야 할 정합성 조건이 생각보다 많았습니다.

이때 경계를 따져 본 경험은 이후 0→1 서비스를 구축할 때 도움이 됐습니다. **실제로 서비스를 만들고 운영해보니, 한 로직을 설계할 때도 실패를 어떻게 감지할지, 데이터가 어디까지 반영될지, 실패 후 어떻게 복구할지까지 정해야 서비스를 안정적으로 운영할 수 있다**는 점이 더 분명해졌습니다.

이 미니 프로젝트의 구현은 실무에 바로 쓰기에는 보완할 부분이 많습니다. 이번에는 그중 트랜잭션 경계와 재처리에 집중했습니다. **주문이 커밋된 뒤 발행이 끊기면, 재고 반영을 다시 시작할 기록이 남는가?** 주문과 Outbox의 저장 시점부터 실제 재시도 범위까지 이 질문을 따라 확인했습니다.

## 트랜잭션이란? {#transaction}

트랜잭션은 여러 데이터 변경을 하나처럼 처리하는 단위입니다. ACID는 원자성(전부 반영하거나 취소), 일관성(정의한 제약 유지), 격리성(동시 실행의 간섭 통제), 지속성(커밋한 결과 유지)을 뜻합니다.

주문 요청부터 재고 반영까지는 업무 관점에서 하나의 **비즈니스 트랜잭션**으로 볼 수 있습니다. 다만 전체가 한 번에 커밋되거나 롤백되는 것은 아닙니다. 주문과 Outbox는 같은 DB 트랜잭션에서 저장하고, Consumer의 처리 이력과 재고 차감은 별도 DB 트랜잭션에서 처리합니다. Redis 선차감과 Kafka 전송도 각각 따로 일어납니다. 그래서 이 흐름의 정합성을 확인하려면 각 단계에 무엇이 남고, 실패했을 때 어디서 다시 시작할 수 있는지 봐야 합니다.

## 커밋 전 기록, 커밋 후 발행 {#flow}

요청이 들어오면 Redis의 가용 재고를 먼저 줄여 주문할 수 있는지 확인합니다. 주문을 저장한 뒤에는 주문 코드를 이벤트 ID로 넣어 Spring의 `ApplicationEventPublisher`에 재고 감소 이벤트를 전달합니다. 이때는 아직 Kafka에 보내지 않습니다.

이 이벤트를 받는 리스너는 두 개입니다. 하나는 커밋 전에 Outbox를 저장하고, 다른 하나는 커밋 후에 Kafka 발행을 맡습니다. 실제 코드에서 핵심만 줄이면 다음과 같습니다.

```java
@TransactionalEventListener(phase = BEFORE_COMMIT)
void record(DecreaseStockEvent event) {
    outboxRepository.save(OutboxMessage.create(
        event.getEventId(), "stock", event
    ));
}

@TransactionalEventListener(phase = AFTER_COMMIT)
void publish(DecreaseStockEvent event) {
    kafkaPublisher.publishDecreaseStock(event);
}
```

`BEFORE_COMMIT` 리스너는 이벤트 ID와 payload를 `INIT` 상태로 Outbox에 저장합니다. 주문과 같은 트랜잭션 안에서 저장하므로 롤백되면 둘 다 남지 않습니다. 커밋에 성공하면 `AFTER_COMMIT` 리스너가 비동기 Kafka 발행 작업을 넘깁니다. 주문이 확정되기 전에 재고 이벤트가 나가지 않도록 한 순서입니다.

<div class="mermaid">
flowchart TB
  R[Redis 가용 재고 선차감]
  subgraph OT[주문 DB 트랜잭션]
    O[주문 저장] --> B[BEFORE_COMMIT: Outbox INIT]
    B --> M[커밋]
  end
  A[AFTER_COMMIT: 발행 작업 전달]
  K[(Kafka)]
  subgraph CT[Consumer DB 트랜잭션]
    C[처리 ID 기록] --> S[재고 차감]
  end
  R --> O
  M --> A
  A --> K
  K --> C
</div>

Redis 선차감은 주문 DB 트랜잭션 밖에서 일어납니다. 재고 부족이나 메서드 안에서 확인한 주문 저장 실패 때는 Redis 수량을 되돌리지만, Redis와 주문 DB가 함께 커밋되거나 롤백되는 것은 아닙니다.

## 기록이 있어도 복구되지 않는 구간 {#recovery}

Kafka 전송 결과가 돌아오면 콜백이 Outbox 상태를 `SUCCESS` 또는 `FAILED`로 바꿉니다. Kafka 전송과 이 상태 변경은 함께 커밋되지 않습니다. 따라서 어디서 멈췄는지에 따라 남는 기록이 다릅니다.

| 실패 시점 | 남는 기록 | 현재 코드의 후속 처리 |
| --- | --- | --- |
| 주문 DB 커밋 전 롤백 | 주문과 Outbox 모두 없음 | `AFTER_COMMIT` 발행 없음 |
| 커밋 후 Kafka 발행 전 중단 | Outbox `INIT` | 자동 재전송 대상 아님 |
| Kafka 전송 실패를 콜백에서 확인 | Outbox `FAILED` | 이전 날짜의 실패 건을 스케줄러가 재전송 |
| Kafka 전송 성공 후 상태 변경 실패 | Outbox `INIT`일 수 있음 | 성공 여부를 상태만으로 확정할 수 없음 |

Outbox에는 커밋된 주문의 이벤트 내용이 남습니다. 문제는 재전송 스케줄러가 `FAILED`만 읽는다는 점입니다. 커밋 직후 프로세스가 멈춰 `INIT`으로 남은 이벤트는 지금 코드로는 자동 재전송되지 않습니다. `INIT`도 재전송하도록 바꾼다면, Kafka에는 도착했지만 상태만 갱신되지 않은 이벤트가 다시 갈 수도 있습니다.

## 재전달과 재고 차감 {#consumer}

Consumer는 주문 코드를 이벤트 ID로 받아 `processed_event`의 기본 키에 기록합니다. 처음 받은 ID일 때만 재고를 줄이고, 이미 있으면 건너뜁니다. 이력 기록과 재고 차감은 같은 DB 트랜잭션 안에서 처리합니다. 중간에 실패하면 둘 다 롤백되므로, 실패한 이벤트가 다시 오면 처음부터 처리할 수 있습니다.

Consumer 처리에 실패하면 일정 시간 재시도하고, 그래도 실패하면 DLQ로 보냅니다. DLQ에 들어갔다는 사실만으로 재고가 반영됐다고 볼 수 없습니다. 원인을 확인하고 다시 처리할지 판단해야 합니다. Producer의 Outbox는 **발행 상태**를, Consumer의 처리 이력은 **이미 재고를 반영했는지**를 확인하는 데 씁니다.

## 이 흐름의 보장 범위 {#boundary}

`AFTER_COMMIT` 덕분에 롤백된 주문의 이벤트는 발행하지 않습니다. Consumer도 같은 이벤트 ID로 재고를 두 번 차감하지 않도록 처리합니다. 다만 `INIT`이 재전송 대상에서 빠져 있어, 커밋 뒤 발행이 끊긴 경우까지 자동 복구하지는 못합니다. Redis 선차감도 주문 DB와 별도로 확인해야 합니다.

다음에는 `INIT` 상태의 이벤트도 다시 조회하고, 오래 남은 건을 알아볼 수 있게 해야 합니다. 그다음 프로세스를 중단했다가 재기동해 실제로 발행이 이어지는지 확인할 생각입니다. 이 확인을 마치기 전까지는 Outbox가 있다는 이유만으로 발행 누락을 복구한다고 설명하지 않겠습니다.

## Lesson learned {#lesson}

남은 과제도 있습니다. 같은 화면에서 새로고침하거나 요청을 재시도해 주문이 다시 들어오는 경우에는 주문 자체의 멱등성을 지켜야 합니다. 재고 이벤트가 DLQ에 머물면 Redis에서 먼저 줄인 수량과 DB 재고를 어떻게 대조하고 복구할지도 정해야 합니다.

이 미니 프로젝트와 별개로 0→1 서비스를 운영하면서 Redis에 쓰는 메모리 비용이 예상보다 크다는 점도 체감했습니다. 이 프로젝트에서 재고 판단을 Redis에 계속 맡긴다면, 장애 시 replica로 전환할 수 있도록 Sentinel을 두는 구성도 그 비용과 함께 검토해야 합니다. 시도해 볼 기술은 얼마든지 더 있습니다. 이번 미니 프로젝트에서 크게 얻은 것은 지금 규모와 운영 조건에 맞는 전략을 고르고, 나중에 확장할 때 무엇을 더 확인해야 하는지 조금이나마 알게 된 점입니다.
