# JenaNote 아이콘 A안 적용

- 사용자 승인한 A안(J + 본문 줄)을 적용했다. JenaImage v10의 네이비 `#14243A`, 흰색 J 외곽과 겹친 종이를 유지하고 내부 산 모양을 세 줄의 본문으로 교체했다.
- `Resources/JenaNote.svg`를 벡터 원본으로 추가했다. `icon-1024.png`를 교체하여 기존 README 참조에도 반영했다.
- 16~1024px 표준 iconset 크기에서 `Resources/JenaNote.icns`를 생성했다. 기존 Makefile과 Info.plist의 아이콘 경로를 유지했다.
- 기존 PNG/ICNS 백업: `/var/folders/jy/d4hl_blj2wgf55g7gg6nnz0m0000gn/T/jena-note-icon-backup-991zdtxz`.
- ImageMagick의 SVG 변환에서 마스크 뒤 도형이 누락되어, 임시 디렉터리에 설치한 `@resvg/resvg-js`로 렌더링했다. 프로젝트 의존성은 추가하지 않았다.
- PNG 실물 확인, 1024×1024 및 투명 모서리 확인, ICNS 역변환과 Info.plist 검증을 통과했다.
- 아이콘 리소스만 변경하므로 단위 테스트는 추가하지 않았다.
- 릴리스 빌드 `.build/icon-a-preview-20261025/JenaNote.app` 성공. 번들 ICNS 동일성 및 ad-hoc 서명 검증 통과. 기존 ExportController의 allowedFileTypes 사용 중단 경고 1건은 유지했다.
