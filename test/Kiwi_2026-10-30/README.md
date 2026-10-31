# Kiwi 선택 문장 검사 검증

Kiwi 0.24.1 공식 XCFramework와 base CONG 모델, 앱의 실제 `KiwiProofreadingEngine`을 사용한다. 사용자 원고는 읽지 않는다.

```sh
bash scripts/prepare-kiwi.sh
swift test --filter 'KiwiProofreading|AIProofreading'
swift test
make build BUNDLE=.build/JenaNote-Kiwi-review.app
xcrun swiftc -O -parse-as-library Sources/JenaNoteKit/proofreading/KiwiProofreadingEngine.swift test/Kiwi_2026-10-30/device-smoke.swift -F .build/artifacts/jena-note/Kiwi/Kiwi.xcframework/macos-arm64_x86_64 -framework Kiwi -lc++ -o /tmp/jena-kiwi-smoke
/tmp/jena-kiwi-smoke .build/JenaNote-Kiwi-review.app/Contents/Resources/KiwiModel
```

- 전체 444개 테스트 통과. 실제 Kiwi 교정·고유명사·Unicode·줄바꿈·탭·URL 보존, 모델 누락 오류, 작품 요약이 실행 중이어도 기본 검사기가 응답하는지 확인한다. 기존 비교/적용/Undo/취소/원문 변경 충돌 테스트도 유지한다.
- 엔진 준비 후 예문 검사는 약 0.1~1.8ms였으며 반복 30회 중앙값은 약 0.23~0.26ms였다. 이 값은 전체 AppKit 시트 표시 시간이 아니다. 최초 모델 준비는 별도 비용이다.
- `device-smoke.log`는 배포 앱에 복사된 모델로 별도 프로세스에서 실행한 결과다. 첫 항목에는 모델 준비 비용이 포함된다.
- 정상 문장과 틀린 문장을 섞은 소규모 회귀 표본이지 한국어 교정 정확도 벤치마크는 아니다. 모든 문법 오류를 찾거나 모든 이름을 보존한다고 보장하지 않는다.
- 최초 탐색에서 deprecated builder의 오타 테이블과 spacing API 조합으로 네이티브 충돌을 발견했다. 제품은 `kiwi_init`과 별도 `kiwi_typo_prepare`/분석 옵션을 사용하는 경로로 고정했으며 해당 충돌 경로는 사용하지 않는다.
- Kiwi의 오타 허용 사전을 켜면 잘못된 표기가 정상 분석 형태로 남아 교정되지 않았다. 제품에서는 해당 사전과 이형태 통합을 끄고 기본 오타 변환기만 사용한다.
- 원고 내 인명/용어를 자동 수집하거나 사용자 사전을 편집하는 기능, 실시간 밑줄 표시는 이번 변경에 포함하지 않는다.

배포 모델 실측: 첫 로딩 포함 2,572ms, 이후 짧은 예문 0.1~1.6ms. 30회 반복 중앙값 0.230ms, p95 0.263ms. `되요.`는 놓쳤다. 모델 10개 파일 및 라이선스/고지 10개 파일의 복사 전후 SHA-256 일치를 확인했다. macOS arm64에서 검증했으며 구형 OS와 Intel 실기 검증은 별도다.
