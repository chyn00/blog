---
title: "10초 넘는 로그인 API, 메트릭으로 좁히고 로그에서 찾은 단서"
date: 2026-09-29 00:00:00 +0900
description: "Slow API 알림에서 출발해 메트릭으로 원인 후보를 좁히고, 기존 로그에서 Trace 전송 설정의 불일치를 발견한 뒤 운영 변화를 관찰한 과정"
categories: [product]
category_label: "0→1 실제 운영 서비스"
tags: [Prometheus, Grafana, HikariCP, OpenTelemetry, Tempo]
topics: [observability]
image: /assets/images/slow-api-metrics-and-logs.png
permalink: /product/slow-api-metrics-and-logs/
mermaid: true
toc_items:
  - id: signal
    title: "Slack 알림과 첫 확인"
  - id: connection
    title: "DB 커넥션 가설"
  - id: jvm
    title: "GC와 CPU 가설"
  - id: logs
    title: "기존 로그에서 찾은 단서"
  - id: causality
    title: "확인된 문제와 남은 가설"
  - id: result
    title: "재배포 후 관찰"
  - id: next
    title: "알림에서 분석까지의 연결"
---

개인 SaaS의 로그인 API가 간헐적으로 10초 이상 걸린다는 Slack 알림을 받았습니다. 평소에는 정상이고, 한동안 사용하지 않은 뒤 첫 요청에서 느려지는 경우도 있었습니다. 화면 전환이 느리다는 체감만으로 로그인 로직이나 DB를 원인으로 정할 수는 없었습니다.

그래서 알림이 가리킨 시간대의 HTTP 메트릭으로 지연 구간을 먼저 확인하고, DB 커넥션·GC·CPU 순서로 각 가설을 검토했습니다. 메트릭만으로 요청 내부의 병목을 찾지 못해 기존 애플리케이션 로그를 열었고, 종료된 Tempo로 Trace를 계속 전송하려는 설정을 발견했습니다. 설정을 정리해 재배포한 뒤 체감 지연은 사라졌지만, 그 설정이 지연의 직접적인 원인이었는지는 아직 확정할 수 없습니다.

> **판단 기준 / One Perspective** — 각 메트릭이 설명할 수 있는 범위만큼 원인 후보를 좁히고, 남은 요청 내부의 경로는 로그에서 확인한다.

## Slack 알림과 첫 확인 {#signal}

[앞서 구축한 모니터링 경로]({{ '/product/raspberry-pi-monitoring-boundary/' | relative_url }})는 Prometheus가 수집한 HTTP 요청 시간과 JVM 메트릭을 Grafana에서 조회하고, 기준을 넘는 Slow API를 Slack으로 알립니다. 알림에는 API의 URI·Method·상태 코드와 발생 시간대가 있었지만, 요청 내부에서 어디가 느렸는지는 없었습니다. 따라서 Grafana Explore로 이동해 시간 범위를 다시 맞추고 메트릭을 직접 조회해야 했습니다.

먼저 지연이 브라우저·프록시 구간인지, Spring Boot가 측정한 요청 처리 구간인지 구분했습니다.

<div class="mermaid">
flowchart LR
  B["Browser"] --> C["Cloudflare"] --> N["Nginx"] --> S["Spring Boot"] --> D["Database"]
  H["HTTP 요청 시간 메트릭"] -.-> S
</div>

Explore에서 로그인 경로와 `POST`로 범위를 좁혀 `http_server_requests_seconds_max`의 최근 구간 최대값을 확인했습니다. 아래 쿼리의 URI는 공개용으로 일반화한 자리표시자입니다.

```promql
max_over_time(
  http_server_requests_seconds_max{
    uri="<login-uri>", method="POST", status="200"
  }[2m]
)
```

알림 시간대에 상태 코드 200인 로그인 API 시계열에서 10초 이상의 값이 기록돼 있었습니다. 적어도 Spring Boot가 관측한 HTTP 처리 구간에 지연이 있었다는 뜻입니다. 브라우저에서만 느리게 보인 현상으로 한정할 수 없게 됐지만, 이 값은 개별 메서드의 실행 시간을 알려주지 않습니다. 다음으로 로그인 경로에서 계정 조회에 필요한 DB 커넥션을 살폈습니다.

## DB 커넥션 가설 {#connection}

로그인 과정에서는 Spring Security가 사용자 정보를 조회하고 비밀번호를 검증한 뒤 세션을 처리합니다. 유휴 시간 뒤 첫 요청이 느렸던 경험도 있어, 커넥션 획득 지연을 먼저 의심했습니다. HikariCP의 획득 시간은 요청이 풀에서 커넥션을 받기까지의 시간을 보는 지표입니다.

```promql
max_over_time(hikaricp_connections_acquire_seconds_max[30m])
```

조회 구간의 최대 획득 시간은 약 50ms였습니다. 관측된 10초 이상 지연을 커넥션 **획득만으로** 설명하기는 어려웠습니다. 다만 커넥션을 얻은 뒤 SQL이나 트랜잭션 내부 작업이 오래 걸렸을 가능성은 남았습니다. 그래서 커넥션을 빌린 뒤 반환하기까지의 사용 시간을 확인했습니다.

```promql
max_over_time(hikaricp_connections_usage_seconds_max[5m])
```

최대 약 3.8초가 관측됐습니다. 살펴볼 만한 길이지만, 이 값은 SQL 실행 시간만 뜻하지 않습니다. 커넥션을 점유한 동안의 다른 작업도 포함될 수 있고, 풀 전체의 값이라 그 커넥션이 느린 로그인 요청에서 사용됐는지도 알 수 없습니다. 값이 같은 시간대에 나타났다는 사실만으로 DB 쿼리를 병목으로 지목하지 않았습니다.

마지막으로 풀 고갈 여부를 확인했습니다. 최대 커넥션 수가 10개라는 설정값보다 중요한 것은 확보하지 못해 기다리는 요청이 있었는지였습니다.

```promql
max_over_time(hikaricp_connections_pending[2m])
```

해당 시간대의 대기 스레드 수는 0이었습니다. 스크레이프 사이의 짧은 대기를 놓쳤을 수 있으므로 ‘대기가 전혀 없었다’고 단정할 수는 없습니다. 그래도 획득 시간 50ms, 사용 시간 3.8초, 수집 시점의 대기 0을 함께 보면 **커넥션 풀 고갈을 우선 원인으로 볼 근거는 부족**했습니다. 이 단계에서 풀 크기나 최소 유휴 커넥션 수를 바꾸면 원인을 확인하기 전에 운영 설정부터 늘리는 셈이었습니다.

## GC와 CPU 가설 {#jvm}

애플리케이션과 모니터링 도구를 제한된 자원의 서버에서 운영하므로 JVM 정지나 CPU 경합도 확인해야 했습니다. 먼저 Grafana 대시보드에서 메모리 사용량을 봤지만 알림 시간대의 급격한 증가는 관측되지 않았습니다. 이어 GC 일시정지 시간의 최대값을 조회했습니다.

```promql
max_over_time(jvm_gc_pause_seconds_max[5m])
```

관측된 Minor GC 최대 일시정지는 약 63ms였습니다. 이 값만으로 누적 GC 비용이나 모든 JVM 상태를 설명할 수는 없지만, 현재 메트릭에는 10초 이상 지연을 설명할 장시간 GC 정지가 없었습니다.

로그인 과정의 BCrypt 비밀번호 검증은 CPU를 사용하므로 프로세스 CPU도 확인했습니다.

```promql
max_over_time(process_cpu_usage[5m])
```

알림 시간대의 프로세스 CPU 사용률은 최대 약 2.1%였습니다. 특정 스레드의 순간적인 연산이나 스로틀링까지 배제하는 수치는 아니지만, 프로세스 전체에 높은 CPU 부하가 있었다는 근거도 없었습니다.

이 조사는 ‘메트릭이 정상이므로 문제가 없다’는 결론이 아닙니다. HTTP 처리 시간은 길었고, 지금까지 본 풀·JVM 지표는 그 시간을 충분히 설명하지 못했습니다. 따라서 시스템 전체의 자원 설정을 조정하기보다 요청 내부에서 시간이 쓰인 위치를 확인하는 쪽으로 조사 범위를 옮겼습니다.

<div class="mermaid">
flowchart TD
  H["HTTP 처리 10초 이상 확인"] --> A["커넥션 획득 최대 약 50ms"]
  A --> U["커넥션 사용 최대 약 3.8초 · 요청 연결 불명"]
  U --> P["대기 0 · 수집 시점에 풀 고갈 미관측"]
  P --> G["GC 최대 약 63ms · 장시간 정지 미관측"]
  G --> C["프로세스 CPU 최대 약 2.1% · 높은 부하 미관측"]
  C --> R["개별 요청의 실행 경로 확인 필요"]
</div>

## 기존 로그에서 찾은 단서 {#logs}

DB 커넥션 풀·GC·CPU 메트릭으로 우선순위를 낮춘 뒤에는 요청 내부에서 무슨 일이 있었는지 확인해야 했습니다. 로그인 요청은 계정 조회, BCrypt 검증, 세션 처리 등을 거치지만 HTTP 메트릭은 이 단계들을 나누지 않습니다. 구간별 실행 시간 로그를 새로 넣기 전에, 우선 이미 남아 있는 운영 로그에서 단서를 찾기로 했습니다.

Tempo는 요청 내부의 Trace를 보기 위해 도입했지만, 현재는 서버 메모리 부담 때문에 종료한 상태였습니다. 먼저 운영 백엔드 컨테이너 이름을 지정하고, Slack 알림 시간대를 `--since`와 `--until`으로 제한해 `docker logs`를 조회했습니다. 아래 명령의 시각과 컨테이너명은 공개용 변수입니다. 예외 문자열로 미리 거르지 않고 그 시간대의 로그를 살펴봤습니다.

```bash
docker logs --timestamps \
  --since "$ALERT_START" \
  --until "$ALERT_END" \
  "$BACKEND_CONTAINER"
```

다행히 별도 계측 없이도 반복되는 오류 로그가 남아 있었고, 로그인 지연 시각에도 같은 오류가 나타났습니다.

```text
Failed to export spans. The request could not be executed.
java.net.UnknownHostException: tempo
  at io.opentelemetry.exporter.sender.okhttp.internal.RetryInterceptor.intercept(...)
  at okhttp3.internal.connection.RealCall$AsyncCall.run(...)
```

이 로그는 Tempo 서버나 로그인 예외 처리 코드가 남긴 것이 아닙니다. 백엔드에 포함된 [OpenTelemetry HTTP Exporter](https://github.com/open-telemetry/opentelemetry-java/blob/v1.62.0/exporters/common/src/main/java/io/opentelemetry/exporter/internal/http/HttpExporter.java#L114-L121)가 전송 실패를 **자체 로거에 기록**했고, 그 출력이 백엔드 컨테이너 로그에 남은 것입니다.

Tempo 컨테이너는 종료했지만 애플리케이션의 OTLP Trace Exporter 설정은 남아 있었습니다. 수신 저장소인 Tempo를 멈추는 작업과, 애플리케이션이 Span을 생성·전송하지 않게 하는 작업은 서로 다른 설정 경계입니다. 이 경우에는 백엔드가 `tempo` 호스트를 계속 찾으려다 DNS 조회에 실패했고, 전송 실패 로그를 남겼습니다.

## 확인된 문제와 남은 가설 {#causality}

**확인된 사실**은 종료된 Tempo를 향한 Trace 전송 실패가 반복됐다는 것입니다. 메모리가 제한된 운영 환경에서 실패할 전송과 오류 로그를 계속 만드는 구성은 정리할 필요가 있습니다.

**확인하지 못한 부분**은 이 실패가 로그인 응답 시간에 얼마나 기여했는지입니다. `BatchSpanProcessor`의 별도 작업 스레드와 로그의 OkHttp `AsyncCall`은 전송 실패가 요청 처리 스레드에서 동기적으로 발생한 예외가 아님을 보여줍니다. 그렇다고 Span 생성·대기열 처리·반복되는 실패 로그의 자원 비용이 없다고 말할 수는 없습니다. 그 비용이나 느린 로그인 요청의 내부 구간 시간을 측정하지 않았으므로, 오류 발생 시각이 겹친다는 이유만으로 직접 원인을 확정할 수 없습니다.

현재 운영 규모에서는 Tempo를 다시 상시 실행하기보다, 운영 프로파일의 OTLP Trace Exporter를 비활성화하고 Tempo endpoint를 제거했습니다. Trace 샘플링도 끄고 Prometheus 메트릭 수집 설정은 유지했습니다. 커넥션 풀이나 GC 설정은 바꾸지 않았습니다.

## 재배포 후 관찰 {#result}

변경한 설정을 재배포한 뒤 운영에서 로그인 API를 포함해 기존에 느리게 느껴졌던 API들을 다시 사용했습니다. 이전의 전반적인 느림 체감이 사라졌고, 이후 Slow API 알림도 오지 않고 있습니다.

이는 운영 사용과 알림을 통해 확인한 초기 경과입니다. 모든 API의 응답 시간을 변경 전후로 정량 측정한 결과는 아니며, 아직 관찰 기간도 짧습니다. 따라서 설정 불일치의 제거와 느림 현상의 소실이 함께 관측됐다고 기록하고, 인과관계는 단정하지 않겠습니다. 같은 알림이 다시 발생하는지 계속 지켜보고, 지연이 재발하면 로그인 주요 구간을 직접 계측해 사용자 조회·비밀번호 검증·세션 처리 중 어디에 시간이 쓰였는지 확인할 계획입니다.

## 알림에서 분석까지의 연결 {#next}

Slack 알림은 느린 API를 발견하는 데 효과가 있었습니다. 다만 알림을 받은 뒤 Explore에서 시간 범위를 설정하고 HTTP·HikariCP·GC·CPU 쿼리를 반복해서 입력해야 했습니다. 이번 조사는 그 수작업을 줄일 다음 범위도 보여줬습니다.

첫째, **알림에서 관련 대시보드로 이동하는 경로**를 마련할 수 있습니다. URI·Method·상태 코드와 알림 시각을 전달하고, 같은 시간대의 HTTP 최대 응답 시간, 커넥션 획득·사용·대기, 메모리·GC·CPU를 한 화면에 배치하는 방식입니다. 이 화면의 시스템 지표는 해당 요청과 시간대가 겹칠 뿐, 모두 그 요청에 속한 값은 아니라는 표시도 필요합니다. 현재 Slack 알림에서 대시보드로 직접 이동하는 기능은 구현하지 않았습니다.

둘째, 메트릭으로 더 좁히지 못할 때를 위해 **느린 요청의 구간별 실행 시간**을 남길 수 있습니다. 요청 ID와 전체 시간, 인증·세션·후속 처리 시간만 기록하고 로그인 정보는 제외합니다. 임계치를 넘은 요청에만 남기면 로그 비용을 통제하면서 한 요청의 경로를 따라갈 수 있습니다. 이 계측도 아직 적용하지 않았고, 실제 트래픽과 로그량을 본 뒤 기록 범위를 정할 계획입니다.

향후 별도 관측성 자원을 확보해 Tempo를 다시 운영한다면 알림에서 Trace로 연결하는 경로를 검토할 수 있습니다. 그때는 Trace 샘플링으로 느린 요청이 실제 저장되는지, 알림과 요청 ID·Trace ID를 어떻게 연결할지도 함께 결정해야 합니다.

이번 조사에서 메트릭은 병목을 바로 지목하기보다 다음에 볼 경계를 정하는 데 쓰였습니다. 커넥션 풀·GC·CPU를 근거 없이 조정하지 않고 로그까지 이동한 결과, 관측성 구성의 불일치를 발견했습니다. 설정 정리 후에는 체감 지연과 Slow API 알림이 사라진 상태입니다. 이 경과를 계속 관찰하면서, 같은 알림이 다시 왔을 때 요청 내부로 더 빨리 들어갈 수 있는 단서를 남기려 합니다.
