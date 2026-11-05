# 소스 빌드 앱 설치 경로 통일

make install의 설치 경로를 ~/Applications/JenaNote.app에서 /Applications/JenaNote.app으로 변경한다. DMG 드래그 설치 및 PKG 설치 위치와 일치시켜 동일 앱이 두 위치에 설치되는 혼동을 줄인다. Makefile의 삭제·복사·완료 메시지와 README 설치 안내를 함께 갱신했다.

make -n install로 생성 명령의 대상이 /Applications/JenaNote.app임을 확인하고 git diff --check를 통과했다. 실제 설치나 기존 홈 폴더 앱 삭제는 수행하지 않았다.
