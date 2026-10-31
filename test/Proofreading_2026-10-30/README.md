# 선택 문장 검사 검증

> 이 문서는 Apple Intelligence 구현 당시의 검증 기록이다. 현재 기본 검사기는 Kiwi로 전환되었으며 아래 standalone 명령은 당시 소스 기준이다. 현재 재현 방법은 `test/Kiwi_2026-10-30/README.md`를 참조한다.

실제 프로덕션 추론 큐·요약 가용성 검사·교정 어댑터를 최소 도메인 스텁과 함께 컴파일한다. 사용자 원고 대신 직접 만든 예문만 검사한다.

```sh
xcrun swiftc -parse-as-library Sources/JenaNoteKit/ai/AILocalInferenceQueue.swift Sources/JenaNoteKit/ai/AIWorkLocalSummarizer.swift Sources/JenaNoteKit/ai/AISelectionProofreader.swift test/Proofreading_2026-10-30/device-smoke.swift -o /tmp/jena-proofreading-smoke
/tmp/jena-proofreading-smoke
swift test --filter 'AIProofreading|AIWorkLocalSummarizer'
```

2026-10-30 실기 결과는 `device-smoke.log`에 기록했다. 모델 available 상태에서 4개 예문이 약 0.6~8초에 응답했다. `오늘학교에갔다.` → `오늘 학교에 갔다.`, `회의가 끝낫습니다.` → `회의가 끝났습니다.`로 교정했다. `안녕 하세요.`는 교정하지 못했다. 고유명사 예문은 유지했다. 이 표본은 정확도 평가가 아니며 기기·모델·동시 작업에 따라 결과와 시간이 달라진다.

자동화 테스트는 우선순위, 취소, 대기 포함 시간 제한, 입력 제한, 결과 검증, 선택 범위, 적용 전 원문 보존, Undo, 페이지 모드 및 문서 변경 충돌을 확인한다. 테스트 렌더 `/tmp/jena-proofreading.png`는 AppKit 비트맵으로 일부 시스템 레이어가 누락되므로 완전한 창 외관 검증을 대신하지 않는다.
