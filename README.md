# 기술과 판단

Jekyll과 GitHub Pages로 구성한 개인 기술 블로그입니다.

## 로컬 실행

GitHub Pages와 같은 의존성으로 실행하려면 Ruby 3.3 계열과 Bundler가 필요합니다.

```bash
bundle install
bundle exec jekyll serve
```

프로덕션 빌드 확인:

```bash
JEKYLL_ENV=production bundle exec jekyll build --trace
bundle exec ruby scripts/check_internal_links.rb _site
```

현재 macOS 기본 Ruby처럼 버전이 낮은 환경에서는 Docker로 동일하게 확인할 수 있습니다.

```bash
docker run --rm -p 4000:4000 \
  -e BUNDLE_PATH=/site/vendor/bundle \
  -v "$PWD:/site" -w /site ruby:3.3 \
  sh -lc 'bundle install && bundle exec jekyll serve --host 0.0.0.0'
```

`_config.yml`의 `url`, `baseurl`, `github_username`은 실제 저장소와 계정을 확정한 뒤 입력합니다.

## 글 작성

글은 `_posts/YYYY-MM-DD-slug.md`에 추가합니다.

```yaml
---
title: "글 제목"
date: 2026-09-24 09:00:00 +0900
description: "카드와 검색 메타데이터에 사용할 요약"
categories: [production]
category_label: "실무"
tags: [Java, Oracle]
image: "/assets/images/example.webp"
toc: true
toc_items:
  - id: context
    title: "문제의 맥락"
mermaid: false
---
```

`image`를 생략하면 저작권 문제가 없는 CSS 기본 썸네일이 표시됩니다. Mermaid가 필요한 글만 `mermaid: true`로 설정합니다.

## Copyright

© 2026 chyn00. All rights reserved. 별도 표시가 없는 원문·디자인·자체 제작 자산의 무단 복제와 재배포를 허용하지 않습니다. 자세한 내용은 [copyright.md](copyright.md)를 확인하세요.
