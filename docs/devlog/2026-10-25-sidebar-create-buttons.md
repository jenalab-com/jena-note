# 사이드바 새 문서 / 폴더 추가 버튼

- 요청: 상단에 새 문서 버튼을 추가하고 폴더 추가와 아이콘을 구분한다.
- 기존 `plus`를 `folder.badge.plus`로 교체하고, 왼쪽에 `doc.badge.plus` 버튼을 추가했다. 헤더의 순서는 정렬 → 새 문서 → 폴더 추가다.
- 새 문서는 파일 메뉴의 ⌘N과 동일한 `NSDocumentController.newDocument`에 연결했다. 새 창에서 미저장 문서를 생성하는 기존 동작을 사용하며 폴더에 파일을 자동 생성하지 않는다.
- 기존 다국어 새 문서 문자열을 툴팁과 접근성 레이블에 재사용했다. 폴더 추가 동작은 유지한다.
- 변경 전 SidebarViewController 백업: `/var/folders/jy/d4hl_blj2wgf55g7gg6nnz0m0000gn/T/jena-sidebar-buttons-backup-ff_qq7n8`.
- 두 SF Symbols의 실제 NSImage 로드와 diff 공백 검증을 통과했다. 단순 버튼 연결 변경으로 별도 단위 테스트는 추가하지 않았다.
- 릴리스 빌드 및 ad-hoc 서명 검증 통과: `.build/sidebar-buttons-preview-20261025/JenaNote.app`. 기존 ExportController의 allowedFileTypes 사용 중단 경고 1건은 유지했다.
