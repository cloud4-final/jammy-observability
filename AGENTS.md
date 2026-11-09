# jammy-observability 작업 규칙

## 팀 기준 (jammy-docs)

- 평소에는 팀 기준 문서를 읽지 않는다. 아래 경우에만 관련 부분을 읽는다.
  - 다른 파트와 함께 쓰는 값을 바꾸거나 새로 쓸 때: 버전, 포트, 주소, 이름, API, DB, label, 태그, 아키텍처 경계, MVP 범위
  - 코드, 문서, 사용자 설명이 서로 맞지 않을 때
  - 사용자가 팀 기준 확인을 요청할 때
- `contracts.md`는 분류별로 읽는다. 분류: NET(대역), ADDR(주소), PATH(통신 경로), NAME(이름·태그), API(collector API), DB, OBS(관측), AWS, AI, VER(최소 버전·레거시 금지).
  `curl -sL https://raw.githubusercontent.com/cloud4-final/jammy-docs/main/contracts.md | awk '/^##/{p=/^### C-(API|DB)-/} p'`
- 결정의 이유, 아키텍처 경계, 파트별 담당(Owner)이 필요하면 아래 문서를 읽는다.
  - `https://raw.githubusercontent.com/cloud4-final/jammy-docs/main/decisions.md`
  - `https://raw.githubusercontent.com/cloud4-final/jammy-docs/main/architecture.md`
  - `https://raw.githubusercontent.com/cloud4-final/jammy-docs/main/mvp-roles.md`
- 작업이 기준과 어긋나면 진행 전에 사용자에게 알린다. 기준을 바꾸려면 팀 합의가 필요하다.
- 사용자가 요청하면 jammy-docs 변경 PR을 만든다.
  1. `d="$(mktemp -d)" && gh repo clone cloud4-final/jammy-docs "$d/jammy-docs" && cd "$d/jammy-docs" && git switch -c docs/<주제>`
  2. jammy-docs `README.md`의 작성 규칙을 따라 고친다.
  3. commit하고 `git push -u origin HEAD` 후 `gh pr create -R cloud4-final/jammy-docs`로 PR을 연다.
  4. 코드 PR 본문에 그 PR 링크를 적는다. 링크한 PR이 merge되기 전에는 `docs-link-check`가 실패한다.
- PR을 올리기 전에 diff를 셀프 리뷰한다. 확인할 것: 팀 약속 위반, merge 후 장애, 코드 결함, 다른 파트가 함께 쓸 때 깨짐, 다른 파트도 고쳐야 하는 영향.
