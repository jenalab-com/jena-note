# Foundation Models 검증

- `swift-test.log`: 전체 397개 테스트 통과.
- `targeted-test.log`: 최종 상태 사유 툴팁 변경 후 관련 33개 테스트 통과.
- `release-build.log`: 릴리스 앱 빌드 성공.
- `linkage.log`: FoundationModels가 LC_LOAD_WEAK_DYLIB로 연결됨. 구형 OS 실기 실행을 대신하지 않는다.
- `device-smoke.swift` / `.log`: 실제 SDK 직접 호출. available 및 한국어 지원 확인, 첫 가상 설정에서 guardrailViolation 기록.
- `adapter-smoke-before-prompt-fix.log`: 최초 영어 지시로 한국어 이름/언어가 변형된 결과.
- `adapter-smoke.swift` / `.log`: 실제 프로덕션 요약 어댑터를 한국어 설정/사건으로 실행. 도메인 타입은 최소 스텁이며 요약 구현은 앱 소스를 그대로 컴파일한다.
- `index-episodes.png`: 테스트용 요약 데이터를 사용한 AppKit 컴포넌트 렌더. 실제 macOS 창 전체의 외관 검증은 아님.

재현(저장소 루트에서, macOS 26 이상 및 Apple Intelligence 준비 상태):
```sh
xcrun swiftc -parse-as-library Sources/JenaNoteKit/ai/AIWorkLocalSummarizer.swift test/FoundationModels_2026-10-28/adapter-smoke.swift -o /tmp/jena-foundation-adapter-smoke
/tmp/jena-foundation-adapter-smoke
```

실기 모델 응답은 OS/모델 버전에 따라 달라질 수 있다. 실제 장편 품질·처음 준비 시간은 별도 실사용 평가 대상이다.
