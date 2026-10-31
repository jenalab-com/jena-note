# 로컬 Kiwi 소스와 라이브러리

JenaNote는 이 폴더의 소스를 빌드한 `Kiwi.xcframework`를 사용한다. SwiftPM의 원격 바이너리 다운로드는 사용하지 않는다.

## 폴더 구성

- `source/`: Kiwi 0.24.1의 C++ 엔진, 공개 헤더, C API, 모델 생성 도구 및 참고 문서. 원본 엔진 파일은 변경하지 않은 스냅샷이다.
- `upstream.json`: 원본 저장소·태그·정확한 커밋과 포함한 제3자 라이브러리 커밋/파일 범위.
- `Kiwi.xcframework/`: 소스에서 생성한 macOS arm64+x86_64 정적 라이브러리. Git에는 넣지 않는다. 소스 지문 `SOURCE_SHA256`와 도구 정보 `BUILD_INFO.txt`를 포함한다.
- 모델: `Sources/JenaNoteKit/Resources/KiwiModel/`에 별도 보관한다. 약 104MB이며 Git 제외. 엔진 재컴파일은 모델 재학습을 의미하지 않는다.

소스와 라이선스는 일반 Git 파일로 관리한다. 중첩 Git 저장소/서브모듈이 아니므로 여기서 수정한 코드도 JenaNote 변경사항으로 검토할 수 있다. 원본 갱신 시 `upstream.json`의 커밋과 비교하고 로컬 수정 이력을 보존한다. 모델/평가 데이터/다른 플랫폼 전체 빌드 환경은 포함하지 않는다. Eigen은 `Eigen/`, JSON은 `include/` 헤더와 고지를 포함하며 사용하지 않는 cpuinfo·tclap·googletest는 제외했다. 빌드 옵션은 공식 Swift 빌드와 동일하게 mimalloc ON, cpuinfo OFF를 사용한다.

## 처음 준비

Xcode(선택된 개발자 디렉터리), Swift, CMake가 필요하다. 검증 환경은 CMake 3.31.10이다. CMake가 없다면 프로젝트 전용으로 준비할 수 있다.

```sh
python3 -m venv .build/kiwi-tools
.build/kiwi-tools/bin/python -m pip install cmake==3.31.10
make bootstrap-kiwi
```

`bootstrap-kiwi`는 모델이 없을 때만 GitHub에서 고정 버전/체크섬의 모델을 받으며, 로컬 소스로 양쪽 CPU용 라이브러리를 빌드한다. CMake는 PATH, `CMAKE` 환경 변수 또는 위 가상환경에서 찾는다. 시스템 전역 도구를 자동 설치하지 않는다.

준비된 XCFramework와 모델 폴더를 다른 개발 환경에 복사하면 첫 준비도 다운로드 없이 가능하다. 복사본과 소스의 일치는 `make prepare-kiwi`로 검사한다. 앱 설치/실행에는 소스·CMake·GitHub 연결이 필요 없다.

## 소스 수정 → 반영

```sh
make rebuild-kiwi    # 소스 변경 후 라이브러리 재생성 (네트워크 없음)
make test           # 실제 로컬 라이브러리를 연결해 테스트
make build          # .build/JenaNote.app 생성
```

평소 `make build`/`make test`는 네트워크 접근이나 C++ 재빌드 없이 준비 상태만 검사한다. 소스 또는 빌드 옵션이 바뀌면 오래된 라이브러리를 사용하는 대신 재빌드를 안내하며 실패한다. `swift build`/`swift test` 직접 호출은 이 사전 검사를 우회하므로 먼저 `make prepare-kiwi`를 실행해야 한다.

빌드 중 실패하면 기존 라이브러리는 유지한다. 성공한 뒤 이전 라이브러리는 `.build/kiwi-previous.*/`로 옮겨 두고 교체한다. 생성 파일을 직접 수정하지 않는다. `make clean` 후에도 Vendor 라이브러리와 모델은 유지되지만 CMake 가상환경·중간 빌드 캐시는 다시 준비해야 할 수 있다.

## 소스 읽는 순서

| 관심사 | 파일 | 살펴볼 내용 |
| --- | --- | --- |
| Swift가 호출하는 API | `source/include/kiwi/capi.h` | `kiwi_analyze`, `kiwi_space`, `kiwi_builder_add_word` |
| C API의 실제 연결 | `source/src/capi/kiwi_c.cpp` | C 핸들에서 C++ 객체로 연결, UTF-8 변환, 오류 처리 |
| 띄어쓰기 | `source/src/Spacing.cpp` | `resetWhitespaceInText`, `Kiwi::space`, 품사별 공백 삽입/삭제 |
| 형태소 분석 | `source/src/Kiwi.cpp`, `source/src/KTrie.cpp` | 입력 분석 및 후보 탐색 |
| 사전·사용자 단어 | `source/src/KiwiBuilder.cpp`, `source/include/kiwi/Kiwi.h` | 모델 로딩과 `addWord` 등 사전 구성 |
| 오타 변환 | `source/src/TypoTransformer.cpp` | 변환 규칙과 비용 |
| 형태소를 문장으로 결합 | `source/src/Joiner.cpp`, `source/src/Combiner.cpp` | 조사·어미 결합과 표면형 생성 |
| 미등록 단어 점수 | `source/src/UnkFormScorer.cpp` | 알 수 없는 형태 후보 평가 |
| 언어 모델 | `source/src/CoNgramModel.cpp` | 모델을 이용한 분석 점수 계산 |

앱 쪽 출발점은 `Sources/JenaNoteKit/proofreading/KiwiProofreadingEngine.swift`다. 여기서 표기 보완 → Kiwi 분석/결합 → 띄어쓰기 → 공백 보호를 수행한다. 개인 사전은 현재 후보를 숨기는 필터이며 Kiwi 내부 `addWord`와 연결되어 있지는 않다.

`리에느` 예문을 더 조사하려면 `Spacing.cpp`의 공백 초기화와 토큰별 조합, C API 옵션, 사용자 단어 등록을 순서대로 비교하는 것이 좋다. 이번 전환은 엔진 코드를 수정하지 않고 빌드 경로만 바꾼다.

## 라이선스

원본 `source/LICENSE`, `source/NOTICE`와 의존성별 고지를 보존한다. 배포 앱에는 기존 `Resources/ThirdParty/Kiwi/` 고지를 계속 포함한다. 향후 원본 파일을 수정할 때는 파일에 변경 사실을 표시하고 변경 이유·원본 커밋을 기록한다. 원본 공식 저장소: https://github.com/bab2min/Kiwi
