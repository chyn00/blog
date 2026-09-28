---
title: "주문부터 재고 감소까지, 커머스로 배우는 Kafka의 한 흐름"
date: 2026-08-15 09:00:00 +0900
description: "주문과 이벤트를 함께 영속화하고, Publisher와 Consumer가 재고 감소까지 연결하는 한 흐름을 따라갑니다."
categories: [engineering]
category_label: "Engineering"
tags: [Kafka, Messaging, MySQL]
topics: [backend]
image: /assets/images/thumb-kafka-first-step-realized.png
home_rank: 6
mermaid: true
toc_items:
  - id: question
    title: "주문과 재고 사이"
  - id: flow
    title: "하나의 흐름"
  - id: persistence
    title: "발행 전에 남기는 이유"
  - id: publisher
    title: "Publisher의 책임"
  - id: consumer
    title: "재고 반영과 실패 격리"
  - id: comparison
    title: "RabbitMQ와 다른 관점"
  - id: boundary
    title: "이번 글의 경계"
---

## 주문과 재고 사이 {#question}

사용자가 주문을 완료하면 재고도 줄어야 합니다. 한 애플리케이션과 데이터베이스 안에서는 두 작업을 하나의 트랜잭션으로 묶을 수 있지만, 주문과 재고를 서로 다른 시스템이 맡는 순간 질문이 달라집니다.

주문은 저장됐는데 이벤트 발행에 실패하면 어떻게 복구할까요. 재고를 줄인 Consumer가 응답을 남기기 전에 중단되면 같은 이벤트를 다시 처리해도 될까요. 계속 실패하는 이벤트 하나가 다음 처리를 막는다면 어디로 격리해야 할까요.

Kafka를 이해하기 위해 모든 기능을 한꺼번에 살펴보지는 않았습니다. 이번 글은 **주문 한 건이 만들어진 뒤 재고 수량이 감소하기까지**의 흐름만 따라갑니다. Kafka가 이 사이에서 무엇을 맡고, 신뢰할 수 있는 결과를 만들기 위해 애플리케이션이 무엇을 책임해야 하는지가 핵심입니다.

## 하나의 흐름 {#flow}

전체 흐름은 다음과 같습니다.

<div class="mermaid diagram-wide">
flowchart LR
  C[주문 요청] --> O[주문 저장]
  O --> Q[(발행할 이벤트 영속화)]
  Q --> P[Outbox Publisher]
  P --> K[(Kafka Topic)]
  K --> S[재고 Consumer]
  S --> D{처리 성공?}
  D -->|성공| I[(재고 감소)]
  D -->|재시도 후 실패| DLQ[(DLQ)]
</div>

여기서 Kafka는 주문 데이터베이스와 재고 데이터베이스를 하나의 트랜잭션으로 만들어주지 않습니다. 주문 시스템은 발행해야 할 사실을 잃지 않아야 하고, Publisher는 그 사실을 Kafka에 전달해야 하며, Consumer는 같은 이벤트가 다시 와도 재고를 중복으로 차감하지 않아야 합니다.

메시지 브로커를 도입했다고 신뢰성이 자동으로 생기는 것이 아니라, 각 경계의 실패를 복구 가능한 상태로 남겨야 한 흐름이 완성됩니다.

## 발행 전에 남기는 이유 {#persistence}

주문을 저장한 다음 곧바로 Kafka에 전송하는 코드부터 생각할 수 있습니다.

```java
orderRepository.save(order);
kafkaTemplate.send("order-created", event);
```

두 줄 사이에서 프로세스가 중단되면 주문은 존재하지만 재고 시스템은 그 사실을 알 수 없습니다. 반대로 Kafka 전송 이후 주문 트랜잭션이 롤백되면 존재하지 않는 주문의 재고가 줄어들 수 있습니다.

그래서 주문과 **발행할 이벤트**를 같은 로컬 트랜잭션 안에서 저장했습니다. Kafka 전송 자체를 데이터베이스 트랜잭션에 억지로 포함하는 대신, 나중에 다시 발행할 수 있는 근거를 먼저 영속화합니다.

```java
@Transactional
public OrderId placeOrder(PlaceOrder command) {
    Order order = orderRepository.save(Order.create(command));

    eventOutboxRepository.save(
        OutboxEvent.ready(
            order.getId(),
            "ORDER_CREATED",
            order.toEventPayload()
        )
    );

    return order.getId();
}
```

이 트랜잭션이 커밋되면 주문과 발행 대기 이벤트가 함께 남고, 롤백되면 둘 다 남지 않습니다. 발행이 잠시 실패해도 주문 데이터베이스에 재시도의 기준이 남는 것이 이 설계의 목적입니다.

## Publisher의 책임 {#publisher}

Outbox Publisher는 `READY` 상태의 이벤트를 읽어 Kafka에 전달하고, 브로커가 전송을 확인한 뒤에만 발행 완료 상태로 바꿉니다.

```java
public void publish(OutboxEvent event) {
    kafkaTemplate.send("order-created", event.key(), event.payload())
        .whenComplete((result, error) -> {
            if (error == null) {
                eventOutboxRepository.markPublished(event.id());
                return;
            }
            eventOutboxRepository.recordFailure(event.id(), error.getMessage());
        });
}
```

예시는 핵심 흐름만 단순화한 코드입니다. 실제로는 한 번에 읽을 개수, 동시에 실행되는 Publisher 사이의 선점, 재시도 간격과 최대 횟수, 오래 남은 이벤트의 관찰 방법을 함께 정해야 합니다.

여기에도 중복 가능성은 남습니다. Kafka 전송은 성공했지만 `PUBLISHED` 상태를 기록하기 전에 Publisher가 중단되면 같은 이벤트가 다시 발행될 수 있습니다. Publisher는 **유실을 막기 위해 재발행할 수 있는 구조**를 만들고, Consumer는 **재전달돼도 결과가 중복되지 않는 구조**를 만들어야 합니다.

## 재고 반영과 실패 격리 {#consumer}

재고 Consumer는 이벤트 ID를 처리 이력에 남기고 재고 감소와 같은 트랜잭션으로 묶습니다. 이미 처리된 ID라면 다시 재고를 줄이지 않습니다.

```java
@Transactional
public void consume(OrderCreated event) {
    if (!processedEventRepository.tryInsert(event.eventId())) {
        return;
    }

    inventoryRepository.decrease(
        event.productId(),
        event.quantity()
    );
}
```

일시적인 데이터베이스 연결 실패처럼 다시 시도할 가치가 있는 오류는 제한된 횟수만큼 재시도합니다. 계속 실패하는 이벤트는 DLQ로 보내 정상 이벤트의 진행과 분리합니다.

<div class="mermaid diagram-wide">
flowchart LR
  K[주문 이벤트] --> C[재고 Consumer]
  C --> R{처리 결과}
  R -->|성공| ACK[Offset 진행]
  R -->|일시적 실패| RETRY[제한된 재시도]
  RETRY --> C
  RETRY -->|재시도 소진| DLQ[(DLQ)]
  DLQ --> OP[원인 확인과 재처리 판단]
</div>

DLQ는 실패를 해결하는 저장소가 아닙니다. 반복 실패가 전체 소비 흐름을 막지 않도록 격리하고, 운영자가 원인과 이벤트 내용을 확인해 수정·재처리·폐기 중 하나를 판단할 수 있게 만드는 경계입니다. 따라서 DLQ 적재 건수와 체류 시간을 관찰하지 않으면 실패를 보이지 않는 곳으로 옮긴 것에 불과합니다.

## RabbitMQ와 다른 관점 {#comparison}

RabbitMQ와 Kafka를 단순히 “작은 시스템과 큰 시스템”으로 나누기는 어렵습니다. 둘 다 여러 전달 방식을 구성할 수 있지만, 기본적으로 문제를 바라보는 중심이 다릅니다.

| 관점 | RabbitMQ | Kafka |
| --- | --- | --- |
| 중심 모델 | Exchange가 메시지를 목적 Queue로 라우팅하고 Consumer에게 전달 | Producer가 Topic의 로그에 Record를 추가하고 Consumer가 Offset을 따라 읽음 |
| 처리 이후 | ACK를 기준으로 Queue의 메시지 생명주기를 관리 | 보존 기간 동안 로그를 유지해 다른 Consumer가 독립적으로 읽거나 재처리 가능 |
| 잘 맞는 질문 | “이 작업을 처리할 대상에게 어떻게 전달할까?” | “이 사건을 어떤 시스템들이 각자의 속도로 소비할까?” |

RabbitMQ는 목적지로 메시지를 라우팅하고 처리 여부를 관리하는 작업 전달에 강점이 있습니다. Kafka는 디스크 기반 로그에 이벤트를 남기고, 여러 Consumer Group이 같은 사건을 서로 독립적으로 소비하거나 필요한 지점부터 다시 읽는 구조에 강점이 있습니다.

주문 이벤트를 재고뿐 아니라 알림, 정산, 분석처럼 서로 다른 시스템이 각자의 속도로 사용하고, 소비자가 늘어나거나 처리량이 커질 가능성이 있다면 Kafka의 모델이 확장에 유리합니다. 반대로 특정 작업자에게 메시지를 전달하고 복잡한 라우팅과 즉시 처리가 중심이라면 RabbitMQ가 더 자연스러울 수 있습니다. 확장성이 좋다는 말은 처리량 숫자만이 아니라 **생산자와 여러 소비자의 생명주기를 독립적으로 확장할 수 있다**는 의미에 가깝습니다.

## 이번 글의 경계 {#boundary}

Kafka에는 Partition별 순서 보장, Consumer Group 재조정, Offset Commit, 복제와 장애 복구처럼 더 많은 주제가 있습니다. 하지만 이 글에 모두 넣으면 주문에서 재고 감소까지 이어지는 핵심 흐름이 흐려집니다.

이번 관점에서 남겨야 할 기준은 세 가지입니다.

- 주문 시스템은 발행할 사실을 데이터베이스에 먼저 남겨 유실 가능성을 줄인다.
- Publisher의 재발행 가능성을 전제로 Consumer의 비즈니스 결과를 중복되지 않게 만든다.
- 반복 실패는 DLQ로 격리하되 관찰과 재처리 기준까지 운영 흐름에 포함한다.

Kafka를 이해한다는 것은 기능 목록을 외우는 일이 아니라, 하나의 비즈니스 사건이 분산된 시스템을 지나 결과로 이어질 때 각 경계가 무엇을 보장하는지 설명할 수 있는 일에 가깝습니다. 다음 글에서 순서 보장을 다룬다면 “Partition은 하나일 때 순서가 보장된다”는 문장보다, **어떤 비즈니스 순서가 왜 보존되어야 하는가**라는 별도의 관점에서 시작하려 합니다.
