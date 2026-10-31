# 로컬 Kiwi 소스 빌드 검증

- 고정 소스/의존성 897개 파일과 원본 체크아웃 바이트 일치, 원본 엔진 무수정.
- native-initial.log: 양쪽 아키텍처 최초 컴파일(원본 경고 포함), 빌드 도중 지문 계산 변경 감지로 교체 거부.
- native-final.log: 변경 확정 후 증분 재빌드·로컬 XCFramework 생성 성공.
- package.json: Kiwi BinaryTarget이 Vendor/Kiwi/Kiwi.xcframework를 참조.
- tests.log: 새 scratch-path에서 실제 로컬 라이브러리로 469개 테스트 통과. 리에느 정상 문장 회귀 포함.
- offline-build.log: `sandbox-exec -p '(version 1)(allow default)(deny network-outbound)' swift build --disable-sandbox -c release --product JenaNote` 성공. 외부 샌드박스의 네트워크 차단은 유지하며 내부 SwiftPM 중첩 sandbox만 해제했다.
- preflight.log: 동일 네트워크 차단 상태에서 준비 완료·소스 변경·라이브러리 메타데이터 누락·모델 버전 불일치 검사. 종료 시 파일 복원.
- app-build.log: 일반 make build 앱 패키징 성공.

XCFramework에 arm64+x86_64 슬라이스가 포함됨을 lipo로 확인했다. 테스트 실행 환경은 Apple Silicon이며 Intel 실기 검증은 하지 않았다. 설치 앱 교체·커밋·푸시 없음.
