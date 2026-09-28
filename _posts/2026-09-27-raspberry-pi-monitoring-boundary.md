---
title: "자원의 한계 속에서 최소한의 운영 모니터링을 구축한 이야기"
date: 2026-09-27 02:00:00 +0900
description: "기존 Prometheus와 Raspberry Pi를 연결해 운영 서비스 밖에 Alert 평가 경로를 만들고, 실제 Slow API 신호를 받기까지의 과정"
categories: [product]
category_label: "0→1 실제 운영 서비스"
tags: [Raspberry Pi, Grafana, Prometheus, SSH, Slack]
topics: [observability]
featured_rank: 4
image: /assets/images/thumb-raspberry-monitoring-realized.png
permalink: /product/raspberry-pi-monitoring-boundary/
mermaid: true
toc_items:
  - id: problem
    title: "같은 서버에 있던 감지 경로"
  - id: architecture
    title: "분리한 범위"
  - id: constraints
    title: "제한된 환경의 챌린지"
  - id: alerts
    title: "두 가지 감지 규칙"
  - id: tracing
    title: "Tracing 대신 남긴 단서"
  - id: verification
    title: "현재 운영 상태"
  - id: boundary
    title: "남은 경계"
---

1인 개발로 운영하는 서비스라 NCP 운영 서버도 최소 사양으로 시작했습니다. 이 서버에 Spring Boot 애플리케이션과 Prometheus가 함께 있었습니다. 메트릭은 수집하고 있었지만, 같은 서버에 문제가 생기면 이를 조회하고 알려줄 경로도 함께 영향을 받을 수 있었습니다.

별도 모니터링 서버를 추가하는 대신, 보유하고 있던 Raspberry Pi 3 B+에 Grafana를 설치했습니다. 기존 Prometheus의 수집·저장 구조는 유지하고, 외부에서 조회하고 Alert를 평가하는 역할만 분리했습니다.

> **판단 기준 / One Perspective** — 모니터링 전체를 복제하지 않고, 제한된 자원으로 운영 이상을 먼저 감지할 수 있는 경로를 서비스 밖에 둔다.

## 같은 서버에 있던 감지 경로 {#problem}

기존 구조에서는 애플리케이션과 Prometheus가 같은 서버의 자원과 네트워크를 공유했습니다. 정상일 때는 문제가 없지만 서버 단위 장애가 발생하면 메트릭 조회와 Alert 평가도 함께 중단될 수 있었습니다.

그렇다고 별도 서버에 Prometheus와 Trace 저장소까지 모두 구성하면 현재 서비스보다 모니터링의 운영비용이 먼저 커집니다. 이번 작업은 고가용성 모니터링 플랫폼을 만드는 것이 아니라, 현재 운영 규모에서 필요한 감지 경로를 하나 더 확보하는 문제로 좁혔습니다.

## 분리한 범위 {#architecture}

<div class="mermaid diagram-wide">
flowchart LR
  subgraph NCP["운영 서버"]
    APP["Spring Boot"] --> ACT["Actuator / Micrometer"]
    PROM["Prometheus · internal"] -->|scrape| ACT
  end
  subgraph PI["Raspberry Pi 3 B+"]
    TUNNEL["SSH forward · local"]
    GRAFANA["Grafana"] -->|PromQL| TUNNEL
    GRAFANA --> ALERT["Alert Rules"]
  end
  LOCAL["로컬 관리 환경"] -.->|"관리용 SSH tunnel"| GRAFANA
  TUNNEL -->|"Pi에서 시작한 SSH 연결"| PROM
  ALERT -->|"HTTPS webhook"| SLACK["Slack"]
</div>

- 운영 서버는 애플리케이션 메트릭의 수집과 보관을 계속 담당합니다.
- Raspberry Pi는 Grafana 조회와 Alert 평가를 담당합니다.
- Prometheus와 Grafana는 공개 포트 대신 SSH 터널로 연결합니다.
- 관리 화면은 로컬에서 필요할 때만 별도 SSH 터널로 접근합니다.

이 구조는 Alert 평가 장비를 운영 서버와 분리하지만, 메트릭 원본은 여전히 운영 서버의 Prometheus에 둡니다. 따라서 운영 서버 전체의 상태를 독립적으로 판정하는 구조라기보다, Raspberry Pi에서 Prometheus를 조회할 수 있는지와 수집된 메트릭에 이상 신호가 있는지를 확인하는 구조입니다.

## 제한된 환경의 챌린지 {#constraints}

Raspberry Pi에는 GUI가 없는 OS와 Grafana만 설치했습니다. 대시보드는 다른 기기의 브라우저에서 확인하고, 메트릭 저장은 기존 Prometheus를 재사용했습니다. Docker나 별도의 Prometheus·Trace 저장소는 현재 목표에 필요하지 않아 추가하지 않았습니다.

1인 개발이라 서비스 기능 개발과 운영 개선을 함께 진행해야 했습니다. 모니터링 구성까지 Dev·QA·운영 환경으로 각각 분리하기는 어려웠습니다. 관리 화면은 로컬에서 확인하되, Alert 평가는 상시 실행되는 Raspberry Pi에 두었습니다. 규칙은 저장된 메트릭의 조회 범위와 임계값을 바꿔 결과를 확인하고, Slack Contact Point 테스트와 실제 알림 수신으로 검증했습니다.

구현에는 다음과 같은 챌린지가 있었습니다.

- 1GB RAM 안에서 상시 실행할 구성요소를 제한할 것
- 운영 서버의 Prometheus를 외부에 공개하지 않고 연결할 것
- 로컬 관리 환경과 무관하게 Alert 평가와 Slack 전송을 유지할 것
- 별도의 Dev·QA 모니터링 환경 없이 규칙과 알림 경로를 검증할 것
- 조회 실패와 실제 API 지연을 서로 다른 신호로 구분할 것
- Raspberry Pi 자체 장애까지 감지하는 구조로 과장하지 않을 것

## 두 가지 감지 규칙 {#alerts}

Alert는 서로 다른 질문 두 개로 나눴습니다.

<div class="mermaid diagram-wide">
flowchart LR
  S["Grafana scheduler"] --> C["규칙 A · vector(1)"]
  C --> CR{"Prometheus 조회 성공?"}
  CR -->|아니요| DE["DatasourceError"] --> CS["Slack · 연결 경로 이상"]
  CR -->|예| CN["정상"]
  S --> P["규칙 B · 최근 5분 max"]
  P --> PR{"최대 응답시간이 기준 초과?"}
  PR -->|예| PA["Slack · Slow API"]
  PR -->|아니요| PN["정상"]
</div>

첫 번째 규칙은 단순한 PromQL을 주기적으로 실행합니다.

```promql
vector(1)
```

정상이라면 항상 값이 반환됩니다. SSH 터널이나 Prometheus에 문제가 생겨 쿼리를 실행하지 못하면 Grafana가 `DatasourceError`를 만들고 Slack으로 전달합니다. 이 규칙만으로 터널·네트워크·Prometheus 중 어디에서 문제가 발생했는지까지 구분하지는 않습니다.

두 번째 규칙은 최근 5분간 URI·Method·상태 코드별 최대 응답시간을 확인합니다. Micrometer가 기록한 API별 최대 응답시간에서 최근 구간의 최댓값을 다시 선택하고, URI·Method·상태 코드가 같은 시계열끼리 묶는 방식입니다. 정확한 지연 요청 건수나 SLA를 계산하려는 목적이 아니라, 어떤 API가 어떤 상태로 얼마나 느렸는지 빠르게 찾기 위한 신호입니다.

조건을 넘긴 시계열이 없으면 결과가 비기 때문에 No Data는 정상으로 처리했습니다. 반면 쿼리 실행 실패는 Error로 남겼습니다. 정상적인 빈 결과와 메트릭을 조회하지 못한 상황을 같은 상태로 보지 않기 위해서입니다.

## Tracing 대신 남긴 단서 {#tracing}

가장 아쉬운 지점은 알림에서 개별 요청의 Trace로 바로 이동할 수 없다는 점입니다. Trace를 수집·저장·조회하려면 별도의 저장소와 운영 자원이 필요합니다. Grafana의 [Tempo 단일 노드 설치 가이드](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/deploy/locally/linux/)도 초기 산정 기준으로 4 CPU와 4~8GB 메모리를 제시합니다. 절대적인 최소 사양은 아니지만, NCP 운영 서버를 최소 사양으로 유지하는 현재 단계에서는 Tempo를 위해 서버를 증설하거나 별도 서버를 추가하지 않기로 했습니다.

Metrics만으로는 느렸던 요청 하나의 호출 경로나 Trace ID를 확인할 수 없습니다. 대신 관련 API의 성능 이상을 놓치지 않도록 PromQL로 최근 구간의 최대 응답시간을 URI·Method·상태 코드별로 출력하고 Alert를 걸었습니다. 발생 시간대를 함께 보면 조사할 API와 로그 범위를 좁힐 수 있습니다. 원인을 바로 보여주지는 못하지만, 제한된 운영비용 안에서 분석을 시작할 단서는 남겼습니다.

## 현재 운영 상태 {#verification}

Slack Contact Point의 테스트 메시지와 실제 API 지연 알림 수신을 확인했습니다. 현재는 로컬 관리 환경에 접속하지 않아도 Raspberry Pi가 규칙을 평가하며, Prometheus 조회 실패나 기준을 넘긴 Slow API가 발생하면 Slack으로 알려줍니다.

실제로 특정 API에서 Slow API 알림이 반복적으로 들어오고 있습니다. 현재 알림에 포함된 URI·Method·상태 코드, 최대 응답시간과 발생 시간대를 기준으로 메트릭과 애플리케이션 로그를 대조하고 있으며, 원인 분석 후 해당 API를 개선할 예정입니다.

아직 개발하고 개선할 기능이 많은 1인 서비스이기 때문에, 관측 환경 자체를 확장하는 일보다 반복 알림이 발생하는 API를 먼저 개선하는 데 우선순위를 두었습니다.

> **현재 상태** — 모니터링 경로 구축은 끝났고, 반복적으로 감지되는 Slow API를 분석하고 개선하는 단계입니다.

## 남은 경계 {#boundary}

| 상황 | 현재 구조 |
| --- | --- |
| Prometheus 조회 실패 | `DatasourceError`로 감지 |
| SSH 터널 단절 | 데이터 소스 오류로 감지 |
| 기준을 넘긴 API 응답 지연 | URI·Method·상태 코드와 함께 알림 |
| Prometheus는 정상이지만 애플리케이션 수집 실패 | 별도 `up` 규칙 필요 |
| 개별 요청과 Trace ID 식별 | 현재 메트릭만으로 불가능 |
| Raspberry Pi 또는 집 인터넷 장애 | 현재 구조에서 감지·전송 불가능 |
| 터널 단절 후 자동 복구 | 인증 제약으로 미구현 |

이번 구성은 장애 원인을 자동으로 판정하지 않습니다. 이상 신호와 확인할 API를 먼저 전달해 분석 시작점을 만드는 역할까지 담당합니다. 다음 작업 범위는 반복 알림이 발생하는 API의 원인 분석과 개선이며, `up` 메트릭과 Trace 연결은 현재 신호만으로 원인을 좁히기 어려울 때 검토할 예정입니다.

운영 서비스의 기능과 안정화가 우선이지만, 제한된 자원 안에서 각 구성요소의 역할과 비용을 직접 나눠본 경험도 남았습니다. 실무에서 변경 영향과 운영비용을 먼저 확인했던 것처럼, 이후 Pod 단위로 확장할 때도 CPU·메모리의 requests와 limits를 관성적으로 정하지 않고 실제 역할과 사용량을 기준으로 판단할 수 있는 준비 과정으로 삼았습니다.
