---
title: "화면마다 달랐던 재고 수량을 하나의 기준으로 만들기"
date: 2026-09-12 09:00:00 +0900
description: "흩어진 재고 계산 근거를 복원하고, 내부 기능과 B2C 앱이 같은 재고 수량을 사용하도록 호출 경계를 통일한 과정"
categories: [production]
category_label: "실무"
tags: [Inventory, API, Legacy, Collaboration]
topics: [collaboration]
featured_rank: 1
home_rank: 1
image: /assets/images/thumb-inventory-interface-realized.png
mermaid: true
toc_items:
  - id: stock-model
    title: "Black box였던 재고 계산"
  - id: agreement
    title: "상품 조회 화면을 기준으로 한 합의"
  - id: response
    title: "계산식보다 호출 경계"
  - id: verification
    title: "코드와 문서로 확인한 변화"
  - id: boundary
    title: "더 큰 변경을 보류한 이유"
  - id: lesson
    title: "이후 변경 기준"
---

발주, 상품 조회, 반품 화면은 같은 상품에도 다른 재고 수량을 보여주고 있었습니다. 운영에서는 상품 조회 화면의 수량을 기준으로 사용했지만, 계산 근거는 코드와 여러 시스템 경계에 흩어져 있었습니다. 누구의 실수라기보다 시스템이 오래 운영되며 기준이 Black box가 된 문제였습니다.

결과만 보면 인터페이스와 API를 하나 만든 작업입니다. 하지만 구현에는 다음과 같은 챌린지들이 있었습니다.

- 수백 줄짜리 쿼리에서 현재 실행되는 재고 계산 경로를 찾을 것
- 더 이상 사용하지 않는 테이블과 실제 계산에 참여하는 테이블을 구분할 것
- 테스트 데이터를 직접 만들기 위해 테이블 관계와 재고 증감 조건을 먼저 분석할 것
- TF 안에서도 레거시 전체를 아는 사람은 거의 없었고, 운영 담당자 3~4명도 각자 맡은 영역의 지식을 가지고 있어 이를 하나의 흐름으로 연결할 것
- 세 팀 이상의 관련 부서와 상품 조회 화면의 수량을 공통 기준으로 사용해도 되는지 검증하고 합의할 것
- 명확한 담당이 없는 그레이 영역을 맡으며 늘어나는 분석 범위와 이후 기준 변경·문의 대응의 책임 범위를 정할 것

> **판단 기준 / One Perspective** — 담당이 불명확해도 반복 문의의 원인이 시스템 로직에 있으면, 백엔드에서 근거를 만들어 합의 가능한 상태까지 맡는다. 저장 구조 전환은 별도 우선순위로 둔다.

이 기준으로 계산 경로를 먼저 복원했습니다. 그 근거로 운영·기획·관련 시스템 담당자에게 공통 재고 수량을 제안했고, 합의된 기준을 코드와 문서에 남겼습니다.

## Black box였던 재고 계산 {#stock-model}

재고 수량은 한 컬럼에 완성된 값이 아니었습니다. POS 판매, 점포 단말, 입고·출하·반품 같은 증감 거래와 본사 시스템의 데이터를 조회 시점에 조합해 계산했습니다. 결과는 보였지만 어떤 입력이 언제 반영되고 어떤 예외가 적용되는지는 한눈에 확인하기 어려웠습니다.

코드를 읽는 데서 끝내지 않았습니다. 실행 경로를 따라 사용 중인 테이블을 분리하고, 재고 증감 조건에 맞는 테스트 데이터를 직접 만들어 화면별 수량을 재현했습니다.

<div class="mermaid">
flowchart LR
  BLACK["BLACK BOX<br/>POS·점포 단말·본사 시스템<br/>입고·출하·반품 등 증감<br/>재고 수량 산출"]
  DOC["문서화된 재고 로직<br/>입력 데이터<br/>반영 시점<br/>업무 예외<br/>재고 수량 기준"]
  BLACK -->|로직 추적·정리| DOC
  classDef blackbox fill:#30363d,color:#ffffff,stroke:#30363d
  classDef evidence fill:#eef1f5,color:#171713,stroke:#68778a
  class BLACK blackbox
  class DOC evidence
</div>

입력부터 결과까지 추적해 반영 시점과 업무 예외를 정리했습니다. 설명할 수 없는 숫자를 그대로 통일하지 않고, 먼저 설명 가능한 재고 수량으로 바꾼 것입니다.

## 상품 조회 화면을 기준으로 한 합의 {#agreement}

운영자가 관행적으로 신뢰하던 상품 조회 화면의 수량을 기준 후보로 삼았습니다. 계산 근거를 정리한 뒤 관련 담당자와 각 업무에서도 사용할 수 있는지 확인했습니다.

합의한 내용은 재고 수량의 정의, 증감 요소, 화면별 사용 기준으로 문서화했습니다. 이후 기준은 담당자의 기억이 아니라 누구나 확인할 수 있는 운영 자산이 됐습니다.

## 계산식보다 호출 경계 {#response}

기존 계산 쿼리는 크게 바꾸지 않았습니다. 같은 계산을 두고도 기능마다 repository에 직접 접근하면 업무 예외를 빠뜨리거나 일부 조건을 다시 구현해 기준이 갈라질 수 있었습니다.

모놀리식 내부의 발주·상품 조회·반품 기능은 Java 인터페이스로 재고 도메인의 상위 로직을 호출하게 했습니다. B2C 앱에는 같은 로직을 사용하는 공통 재고 조회 API를 제공했습니다.

아래 코드는 실제 구현이 아니라 호출 구조만 단순화한 예시입니다. 상세 조회 조건과 업무 규칙은 생략했습니다.

```java
public interface StockQuery {
    StockQuantity getCurrent(String storeCode, String itemCode);
}

final class StockService implements StockQuery {
    private final StockRepository stockRepository;

    @Override
    public StockQuantity getCurrent(String storeCode, String itemCode) {
        StockData data = stockRepository.findForCalculation(storeCode, itemCode);
        return calculate(data); // 기존 업무 규칙과 예외 적용
    }
}
```

내부는 Java 인터페이스, 외부는 API로 경계가 달라도 재고 수량은 같은 도메인 로직에서 나왔습니다. 계산식보다 그 계산을 우회하는 경로를 없앤 것이 핵심이었습니다.

## 코드와 문서로 확인한 변화 {#verification}

재고 수량 차이와 관련된 CS 문의가 줄었고, 문의가 들어와도 정리 문서로 기준을 설명할 수 있었습니다. 감소 폭을 별도 지표로 측정하지는 않았습니다. 신규 점포와 인수인계자는 같은 기준을 확인했고, 운영 개발자는 화면별 쿼리를 다시 추적하지 않아도 됐습니다.

## 더 큰 변경을 보류한 이유 {#boundary}

현재 재고를 하나의 값으로 갱신하는 snapshot 방식과 Redis도 검토했습니다. 그러나 재고를 바꾸는 모든 지점을 연결하고 변경 이력, 동시 업데이트, 장애 복구를 새로 책임져야 했습니다. 여러 부서가 정상 운영 중인 흐름까지 바꾸는 별도 프로젝트 규모였기 때문에, 당시에는 공통 호출 경계까지만 적용했습니다.

## 이후 변경 기준 {#lesson}

이후 재고 수량 변경은 화면별 쿼리보다 공통 로직의 영향 범위를 먼저 확인하게 됐습니다. 계산 기준은 문서에서, 내부와 외부의 호출 경로는 Java 인터페이스와 API에서 확인할 수 있습니다.
