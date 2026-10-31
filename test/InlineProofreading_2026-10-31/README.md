# 본문 자동 교정 후보 표시 검증

```sh
make test
swift test --filter 'LiveProofreading|EditablePagedReader'
make build BUNDLE=.build/JenaNote-Inline-review.app
```

- 전체 451개 테스트 통과.
- 자동 표시 신규 7개: 수정 범위만 표시, Unicode 및 조각 제한, 임시 표시의 원문·서식·Undo 불변, 한글 조합 대기, 늦은 결과 폐기, 스크롤/페이지 자동 연결.
- 페이지 편집/Undo와 자동 표시를 함께 확인한 관련 20개 테스트 통과.
- 최초 전체 테스트에서 NSTextStorage 편집 처리 도중 임시 속성을 제거하면 Undo 후 좌표가 오래된 레이아웃을 참조할 수 있음을 발견했다. 정리를 다음 메인 큐 이벤트로 미루고 실제 스토리지 길이와 표시 범위의 교집합으로 제한한 뒤 전체 회귀를 통과했다.
- `annotations.png`: 테스트용 AppKit NSTextView의 실제 렌더. 기존 ‘회의’ 밑줄 서식은 유지되고, 오류 후보 ‘낫’에만 주황색 표시가 추가된다. 사용자 원고를 사용하지 않았다.
- 표시에는 NSLayoutManager 임시 속성만 사용한다. 현재 화면 우선 검사이며 화면 밖 전체 원고의 검사가 완료됐다는 뜻은 아니다.
