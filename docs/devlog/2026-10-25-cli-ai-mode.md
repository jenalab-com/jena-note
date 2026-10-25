# CLI 기반 AI 모드 구현

## 변경
- 상단 AI 버튼과 우측 문서별 채팅, 가이드/직접 수정, 선택 텍스트 표시.
- AI 패널 사용 중 스크롤 전환·페이지 버튼 비활성화, 패널 종료 후 원래 조판 복원.
- 설정에 Claude Code/Codex/Gemini CLI/Grok CLI 선택, 실행 파일 자동 탐색·직접 선택, 설치·로그인·재확인·공식 안내.
- 설치는 공식 명령을 `.command` 파일로 Terminal에 실행한다. Gemini는 기존 npm/Homebrew가 필요하다. 기존 설치를 자동 갱신하지 않는다.
- 재확인은 버전 실행 뒤 문서 없이 `JENANOTE_OK` 응답을 요청한다. 단순 설치/인증 상태를 실제 연결 성공으로 표시하지 않는다.
- 문서·선택·대화 JSON 컨텍스트, 응답 형식 검사, 요청 당시 문서/서식 snapshot 검사, 변경된 범위의 문서 소유 Undo.
- 원본 파일의 직접 수정 대신 문자 차분으로 편집기에 적용한다. 남아 있는 서식과 이미지 보존; 이미지가 제거되는 수정은 거절한다.
- 요청 취소/시간 초과/출력 크기 제한, 프로세스 그룹으로 CLI 자손까지 관리. 기존 터미널 CLI는 종료하지 않는다.

## 판단과 이슈
- 초기 Process+파이프 wait 방식은 CLI 런처의 하위 프로세스가 파이프를 잡으면 멈출 수 있어 POSIX spawn 그룹과 비차단 읽기로 변경했다. Gemini 재실행 런처도 환경 변수로 비활성화한다.
- 단순 공통 접두·접미 부분 치환은 중간 서식을 잃을 수 있어 유지 문자의 attributed 속성을 보존하는 차분을 적용한다.
- Gemini 임시 작업 디렉터리의 제한 설정이 로드되도록 앱 소유 디렉터리에만 `--skip-trust`를 사용한다.
- Grok은 JSON의 text·stopReason·num_turns를 검사한다. 전역 Stop 훅이 반복 실행되는 실제 환경 문제를 확인했고, JenaNote 전용 GROK_HOME 프로필과 별도 명시적 CLI 로그인으로 분리했다. 기존 토큰 복사·전역 설정 변경은 없다. 관리 정책은 CLI 책임이며 완전한 OS 격리 실행이라고 주장하지 않는다.
- Chat 입력 Undo는 문서 Undo와 별도 관리한다. 문서 전환 시 응답 토큰을 무효화한다.
- 기존 변경 백업: `/var/folders/jy/d4hl_blj2wgf55g7gg6nnz0m0000gn/T/jena-note-before-ai-3f5_hjrx`.

## 검증
자동 테스트는 실제 계정 호출이나 설치를 수행하지 않고 fixture 프로세스를 사용한다. 별도의 수동 smoke test에서 문서 없이 JENANOTE_OK만 요청하여 Claude/Codex/Gemini 정상 응답을 확인했다. Grok 기존 프로필은 Stop 훅으로 반복 응답을 만들어 전용 프로필로 분리했다. 새 Grok 프로필은 사용자가 설정에서 로그인한 뒤 재확인해야 한다.

## 알려진 범위
- 대화는 앱 실행 중 유지되며 재시작하면 복원하지 않는다.
- 요청 컨텍스트 500 KB, 출력 4 MiB, 응답 제한 120초. 넘으면 명시적인 오류를 표시한다.
- AI가 새로 만든 텍스트는 주변 스타일을 상속한다. 기존 Markdown 서식 생성 기능은 별도로 추가하지 않는다.
- 최신 CLI가 제공하는 플래그가 필요하다. 구버전/로그인 만료/사용량 제한은 재확인 실패로 안내한다.
- CLI 설치/브라우저 로그인 사용자 조작은 수동 확인 대상이다. Grok 전용 프로필에는 기존 계정 토큰을 복사하지 않으며 최초 로그인이 필요하다.
- 문자 차분은 공통 접두·접미 부분을 제외한 변경 구간의 두 문자 수 곱이 4,000,000 이하일 때만 수행한다. 큰 재작성은 원본을 보존하고 결과를 채팅에 남겨 작은 문단으로 다시 요청하도록 안내한다.

## 공식 문서 확인 (2026-10-25)
- Claude: https://code.claude.com/docs/en/setup , https://code.claude.com/docs/en/headless
- Codex: https://learn.chatgpt.com/docs/cli , https://learn.chatgpt.com/docs/non-interactive-mode
- Gemini: https://geminicli.com/docs/get-started/installation/ , https://geminicli.com/docs/cli/headless/
- Grok: https://docs.x.ai/build/overview , https://docs.x.ai/build/cli/headless-scripting

## 최종 결과
- `make test`: 198 XCTest 테스트, 실패 0 (`/tmp/jena-ai-all-tests.log`).
- `make build BUILD_DIR=.build/ai-preview-TGAo84`: 릴리스 빌드 성공. 실행 중인 기존 `.build/JenaNote.app`을 덮어쓰거나 종료하지 않았다.
- 앱: `.build/ai-preview-TGAo84/JenaNote.app`. Info.plist 검사 및 ad-hoc 서명 검증 통과.
- 실제 짧은 연결 요청: Claude Code, Codex, Gemini CLI 정상 응답 확인. Grok 기본 프로필의 반복 Stop 훅 문제는 전용 프로필 분리로 대응했으며, 새 프로필의 최초 로그인·연결은 사용자 설정창에서 진행한다.
- 자동 테스트: 문서별 대화/미저장 파일 분리, 파일 저장 시 identity, 선택 Unicode 범위 수정/서식/Undo, 이미지 보호, 변경 충돌, 컨텍스트 제한, 큰 차분 제한, 페이지 복원, 실제 fixture CLI를 통한 채팅→수정, 재확인 버튼, 프로세스 취소·시간 초과·자손 파이프, 전용 환경 전달, Grok 비정상 완료·반복 응답 거절.
