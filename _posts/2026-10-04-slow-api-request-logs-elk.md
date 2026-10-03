---
title: "Slow API 대응 2: ELK에서 Trace ID로 로그 흐름 읽기"
date: 2026-10-04 00:00:00 +0900
description: "모니터링 최신 근황 — 알림의 시간·경로에서 로그를 좁히고, Trace ID로 한 요청의 흐름을 읽도록 바꾼 과정"
categories: [product]
category_label: "0→1 실제 운영 서비스"
tags: [ELK, Logstash, Elasticsearch, Kibana, Observability]
topics: [observability]
image: /assets/images/slow-api-request-logs-elk.svg
permalink: /product/slow-api-request-logs-elk/
toc_items:
  - id: gap
    title: "알림 다음에 남은 수작업"
  - id: contract
    title: "Trace ID를 검색 기준으로"
  - id: route
    title: "운영 서버 밖의 검색 경로"
  - id: reading
    title: "로그를 읽는 방식의 변화"
  - id: boundary
    title: "확인한 범위와 운영 경계"
---

Slow API 알림은 어떤 API가 언제 느렸는지 알려줬습니다. 하지만 그 시간대에 여러 요청이 있으면, 알림의 값만으로는 어떤 요청의 로그를 봐야 할지 알 수 없었습니다. 처음에는 Grafana에서 시간을 다시 맞추고 컨테이너 로그를 훑어 단서를 찾았습니다. 다른 API까지 조사할수록 **알림에서 로그를 좁힌 뒤 한 요청의 흐름을 따라갈 검색 기준**이 필요해졌습니다.

기존 Trace ID를 백엔드 로그에 표시하고, 운영 로그를 로컬 ELK(로그 수집·검색·조회 환경)에서 찾도록 연결했습니다. 이제 알림의 시간·경로와 요청 완료 기록으로 범위를 좁히고, `trace.id`로 해당 요청의 로그와 오류를 시간순으로 읽습니다. 작은 운영 VM에는 검색 스택을 추가로 상시 올리지 않았습니다.

> **판단 기준 / One Perspective** — Slow API 알림 뒤에 한 요청의 흐름을 읽으려면, 기존 Trace ID를 로그에 남기고 ELK에서 검색 가능한 필드로 연결한다.

## 알림 다음에 남은 수작업 {#gap}

[첫 Slow API 조사]({{ '/product/slow-api-metrics-and-logs/' | relative_url }})에서는 알림 시간대로 HTTP·DB·JVM 메트릭을 맞춰 보고, 기존 오류 로그에서 설정 불일치를 찾았습니다. 조사 자체는 가능했지만, 새 알림이 올 때마다 시간 범위를 다시 지정하고 원시 로그를 훑어야 했습니다. 메트릭은 경로와 시각을 알려줘도, 같은 요청에서 발생한 애플리케이션 로그를 묶어주지 않았습니다.

그 뒤 다른 Slow API에서는 프로세스별 RAM·스왑을 확인해 MySQL의 메모리 설정을 줄이고, 운영 DB가 스왑을 쓰지 않도록 제한했습니다. 그 문제는 자원 배분으로 대응했습니다. 여기서 남은 질문은 **다음 알림이 왔을 때 해당 요청의 최종 상태와 로그를 얼마나 빨리 찾을 수 있는가**였습니다.

## Trace ID를 검색 기준으로 {#contract}

먼저 기존 Micrometer Tracing이 생성하는 `traceId`와 `spanId`를 백엔드의 공통 로그 형식에 넣었습니다. 운영에서는 Tempo로 Span을 전송하거나 기록하지 않지만, 요청을 처리하는 동안 Trace ID는 생성되어 로그에 남습니다. Logstash가 이를 `trace.id`로 분리하므로, Kibana에서 오류 로그의 Trace ID를 검색하면 같은 요청 처리 흐름의 로그를 함께 볼 수 있습니다. 실제 로그 조사는 이 값을 주로 사용했습니다.

이후 알림의 시간·경로에서 후보 요청을 더 쉽게 고르기 위해 HTTP 완료 요약을 추가했습니다. 요청이 끝나면 Method·경로·상태 코드·소요시간을 한 줄로 남깁니다. 완료 요약에도 Trace ID가 있으면 그 값을 기준으로 같은 요청 처리 중 남은 로그를 찾습니다. 요약에는 요청 본문·쿼리스트링·헤더·IP를 넣지 않았고, 긴 연결을 유지하는 SSE는 제외했습니다.

## 운영 서버 밖의 검색 경로 {#route}

운영 VM은 메모리 여유가 작습니다. Elasticsearch와 Kibana를 운영 서버에 상시 올리면 관측을 위해 서비스 자원을 다시 쓰게 됩니다. 백엔드 로그는 별도 장치에 모으고, 검색이 필요할 때 Mac의 로컬 ELK를 켜는 경로를 택했습니다.

ELK가 켜져 있는 동안에는 쌓이는 로그 파일의 뒷부분을 5초 간격으로 가져옵니다. Logstash는 로그의 `trace.id`·`span.id`와 오류 메시지·스택트레이스를 분리하고, 완료 요약의 HTTP 상태·경로·소요시간도 구조화해 Elasticsearch에 저장합니다. 읽은 파일 위치를 기억해 재시작 후에도 이어서 읽으며, 전송 중 실패에 대비한 큐도 둡니다. **운영 서버의 메모리 예산을 늘리지 않고 요청의 로그를 검색 가능한 상태로 만드는 것**이 이 구성의 목적입니다.

## 로그를 읽는 방식의 변화 {#reading}

Kibana Discover에서는 로그 수준·HTTP Method·`trace.id`·메시지·응답 상태·소요시간·원문을 나란히 배치했습니다. 알림 시각의 로그를 찾을 때 상태와 소요시간을 먼저 보고, 관련 로그의 Trace ID를 검색해 같은 요청의 메시지와 오류를 이어 읽습니다. 스택트레이스가 필요하면 해당 행을 펼쳐 확인합니다.

<figure id="elk-discover-full" class="article-visual article-visual--expandable">
  <div class="article-visual__frame">
    <a class="article-image-zoom" href="#elk-discover-full" aria-label="Trace ID 중심의 Kibana Discover 화면 확대">
      <img src="{{ '/assets/images/elk-discover-trace-id-blurred.png' | relative_url }}" alt="Kibana Discover에 로그 수준, HTTP Method, Trace ID, 메시지, 응답 상태, 소요시간, 원문 컬럼을 나란히 둔 화면. 실제 로그 값은 흐림 처리했다." width="1500" height="900" loading="lazy">
    </a>
  </div>
  <figcaption>실제 운영 로그를 읽는 Discover 구성. 로그 행은 흐림 처리했고, 이미지를 누르면 컬럼 배치를 확대해 볼 수 있다.</figcaption>
  <a class="article-image-zoom__close" href="#reading" aria-label="확대 이미지 닫기">×</a>
  <a class="article-image-zoom__original" href="{{ '/assets/images/elk-discover-trace-id-blurred.png' | relative_url }}" target="_blank" rel="noopener">원본 크기로 열기 ↗</a>
</figure>

| 조사 단계 | 처음 조사할 때 | 로컬 ELK 연결 후 |
| --- | --- | --- |
| 알림에서 요청 찾기 | 알림 시각을 Grafana와 컨테이너 로그에 각각 맞춤 | Discover에서 알림 시각과 경로를 기준으로 완료 기록의 상태·소요시간을 확인 |
| 한 요청 따라가기 | 같은 시간대의 여러 로그를 직접 대조 | 해당 로그의 `trace.id`로 같은 요청 처리 흐름을 시간순 검색 |
| 오류 확인 | 원시 로그에서 오류와 앞뒤 문맥을 다시 찾음 | Trace ID로 오류·스택트레이스와 앞뒤 애플리케이션 로그를 함께 확인 |

Slack 알림에서 ELK 화면으로 자동 이동하는 링크를 만든 것은 아닙니다. 알림의 시간·경로를 기준으로 후보를 고르는 일은 사람이 합니다. 대신 오류나 완료 기록에서 Trace ID를 확인하면, 그 값을 검색해 같은 요청의 로그를 모아 읽을 수 있습니다. 운영 로그가 로컬 인덱스에 실제로 쌓였고, `trace.id`와 완료 요약 필드가 검색 가능하게 들어온 것을 확인했습니다.

## 확인한 범위와 운영 경계 {#boundary}

로컬 ELK가 켜져 있을 때 로그 파일을 몇 초 간격으로 따라가는 구성입니다. Mac이나 수집 경로가 꺼져 있으면 그동안의 로그는 나중에 가져오므로 항상 즉시 보인다는 보장은 없습니다. Trace ID 검색은 해당 컨텍스트가 남은 로그에 적용됩니다. 요청 목록과 로그 검색 경로가 생긴 것은 확인했지만, 장애 탐색 시간이 몇 분 줄었는지 같은 전후 수치는 측정하지 않았습니다.

웹의 민감 경로를 탐색하는 자동 요청은 **백엔드 요청 로그와 다른 웹 접근 로그**에서 확인했습니다. 그 신호에는 실제 사용자 IP 기준의 로그인 요청 제한과 Cloudflare의 스캔 경로 차단으로 대응했습니다. 로그의 출처에 따라 볼 화면과 차단 위치를 나눴고, Trace ID 검색은 이후 Slow API를 조사할 때 다시 사용할 수 있는 기본 경로로 남겼습니다.
