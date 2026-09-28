---
title: "0→1 서비스 아키텍처"
date: 2026-09-29 02:30:00 +0900
description: "PC 관리자 웹과 모바일 운영 웹을 하나의 백엔드에 연결하고, 개발·배포·관측 경로를 현재 운영 규모에 맞춰 나눈 구조"
categories: [product]
category_label: "0→1 실제 운영 서비스"
tags: [Spring Boot, Docker, Jenkins, Prometheus, Grafana]
topics: [service-design]
home_rank: 1
image: /assets/images/zero-to-one-service-architecture.png
permalink: /product/zero-to-one-service-architecture/
toc_items:
  - id: service
    title: "두 화면과 하나의 백엔드"
  - id: environments
    title: "개발과 운영의 관측 경계"
  - id: delivery
    title: "각자의 배포 단위"
  - id: boundary
    title: "현재 구조의 범위"
---

설치형 프로그램을 실제 사용 흐름에 맞춰 웹 서비스로 옮기면서 관리자에게는 PC 화면이, 현장 운영자에게는 모바일 화면이 필요해졌습니다. 화면은 둘이지만 같은 데이터와 업무 규칙을 다룹니다. 1인 개발로 기능을 만들고 운영까지 맡는 상황에서 중요한 것은 서버를 많이 나누는 일보다 **필요한 곳만 독립적으로 바꾸고, 운영 문제를 발견할 수 있는 경계**를 만드는 일이었습니다.

그래서 두 웹은 배포를 나누되 Spring Boot API와 MySQL은 함께 사용합니다. 개발 환경에는 재현을 위한 Trace를 두고, 운영 환경에는 계속 유지할 수 있는 메트릭과 알림을 남겼습니다.

> **판단 기준 / One Perspective** — 업무 규칙은 한곳에 두고, 변경 주기와 관측 목적이 다른 경로만 분리한다.

## 두 화면과 하나의 백엔드 {#service}

현재 구조를 요청·개발·운영 관점으로 그린 그림입니다. 사용자의 요청 경로와 별도로 배포·관측 경로를 표시했습니다.

<figure class="article-visual">
  <div class="article-visual__frame">
    <a class="article-image-zoom" href="#architecture-image-full" aria-label="서비스 아키텍처 이미지 확대">
      <img src="{{ '/assets/images/zero-to-one-service-architecture.png' | relative_url }}" alt="개발 환경, 운영 환경, Jenkins 배포 경로를 나누어 그린 0→1 서비스 아키텍처" width="1567" height="832">
    </a>
  </div>
  <figcaption>현재 사용 중인 서비스 구조. 이미지를 누르면 확대해서 볼 수 있다.</figcaption>
</figure>

<div id="architecture-image-full" class="article-image-lightbox">
  <a class="article-image-lightbox__close" href="#service" aria-label="확대 이미지 닫기">×</a>
  <img src="{{ '/assets/images/zero-to-one-service-architecture.png' | relative_url }}" alt="개발 환경, 운영 환경, Jenkins 배포 경로를 나누어 그린 0→1 서비스 아키텍처" width="1567" height="832">
  <a class="article-image-lightbox__original" href="{{ '/assets/images/zero-to-one-service-architecture.png' | relative_url }}" target="_blank" rel="noopener">원본 크기로 열기 ↗</a>
</div>

운영 요청은 Cloudflare와 Nginx를 거쳐 두 웹과 공통 API에 닿습니다. PC와 모바일이 다른 화면을 갖더라도 업무 규칙을 두 서버에 복제하지 않았습니다. 사용 방식이 더 달라져 서로 다른 백엔드 계약이 실제로 필요해질 때 분리하면 됩니다. [설치형 프로그램에서 웹으로 옮긴 과정]({{ '/product/operating-service-boundaries/' | relative_url }})에는 이 선택의 출발점을 적었습니다.

## 개발과 운영의 관측 경계 {#environments}

개발 환경에서는 로컬 웹·API·DB로 문제를 재현하고 Tempo와 Grafana DEV로 요청 내부의 Trace를 봅니다. 운영 서버에서는 Spring Boot와 MySQL이 실제 요청을 처리하고 Prometheus가 메트릭을 수집합니다. Raspberry Pi의 Grafana가 SSH 터널을 통해 이를 조회하고, API 지연이나 조회 실패를 Slack으로 알립니다.

운영 서버는 자원이 제한돼 Tempo를 상시 실행하지 않습니다. 대신 메트릭으로 이상을 감지한 뒤 필요한 시간대의 애플리케이션 로그를 확인합니다. 개발에서 자세히 보는 경로와 운영에서 계속 켜둘 경로를 분리한 이유는 <a class="monitoring-link" href="{{ '/product/raspberry-pi-monitoring-boundary/' | relative_url }}">모니터링 구성</a>과 [Slow API 조사]({{ '/product/slow-api-metrics-and-logs/' | relative_url }})에 이어집니다.

## 각자의 배포 단위 {#delivery}

백엔드·PC 웹·모바일 웹은 저장소와 Jenkins 파이프라인이 각각 있습니다. 변경된 영역만 검증하고 이미지를 빌드해 레지스트리에 올린 뒤, Docker Compose로 운영 서버에 반영합니다. 화면만 고쳤을 때 API까지 다시 배포하지 않아도 됩니다. 운영자 Mac의 SSH 접속은 관리 경로이며, 사용자의 요청 경로나 각 파이프라인의 배포 단위와는 별개입니다. [세 파이프라인을 나눈 과정]({{ '/product/jenkins-credential-deployment-pipeline/' | relative_url }})은 별도 글에 정리했습니다.

## 현재 구조의 범위 {#boundary}

지금은 하나의 백엔드와 운영 DB가 두 화면의 업무 규칙을 맡습니다. 서비스 규모에서 필요하지 않은 BFF나 여러 백엔드를 미리 두지 않았고, 배포와 관측 경로는 실제로 다른 주기로 바뀌는 부분만 나눴습니다. 이 구조가 서버 장애까지 견디는 고가용성 구성이라는 뜻은 아닙니다. 운영 서버와 집의 Raspberry Pi 모두 각자 남은 단일 장애 지점이 있습니다.

새 구성요소를 더할 때는 먼저 실제 사용 흐름에서 무엇을 독립적으로 변경해야 하는지, 장애가 어디까지 영향을 주는지 확인하려 합니다. 현재 아키텍처는 그 질문에 답할 수 있을 만큼만 나눈 0→1 서비스의 운영 구조입니다.
