# jammy-observability 작업 규칙

## 팀 기준 (hybrid-docs)

- 작업 전 팀 통일값과 결정을 확인한다. 각 파일의 `## 요약`을 먼저 읽고, 작업과 관련된 섹션만 자세히 읽는다.
  - https://raw.githubusercontent.com/cloud4-final/hybrid-docs/main/contracts.md
  - https://raw.githubusercontent.com/cloud4-final/hybrid-docs/main/decisions.md
- 작업이 위 기준과 어긋나면 진행 전에 사용자에게 알린다. 기준을 바꾸려면 팀 합의가 필요하다.
- 사용자가 요청하면 hybrid-docs 변경 PR을 만든다.
  1. 임시 폴더에 clone한다: `gh repo clone cloud4-final/hybrid-docs "$(mktemp -d)/hybrid-docs"`
  2. hybrid-docs `README.md`의 작성 규칙을 따른다. 바꾼 값과 `## 요약`을 함께 고치고, `decisions.md`의 해당 파트에 결정을 추가한다.
  3. `gh pr create -R cloud4-final/hybrid-docs`로 PR을 연다.
  4. 코드 PR 본문에 그 PR 링크를 적는다. 링크한 PR이 merge되기 전에는 `docs-link-check`가 실패한다.
- PR을 올리기 전에 변경 diff를 셀프 리뷰한다. 확인할 것: 명백한 버그, 위 기준 위반, 테스트 누락.
