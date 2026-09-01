# 초견 트레이너 v1.0 재설계판 - 검증수정

핵심 변경:

- 악보: 직접 그린 음자리표 제거, VexFlow 4.2.2 사용
- 화면 건반: C2~C6 (MIDI 36~84), 기존과 비슷한 크기 유지
- 음원: C2~C6의 49개 반음 각각에 대응하는 별도 MP3를 직접 다운로드해 `midi_36.mp3` ~ `midi_84.mp3`로 1:1 저장
- 런타임 음정 변조/재생속도 변환 없음
- 빌드 중 49개 파일 존재 여부와 파일 해시 중복 여부 검사
- MIDI: 실제 피아노의 MIDI note-on 번호는 전 범위 그대로 수신하며 출제 MIDI 번호와 정확히 같아야 정답
- 실제 MIDI 입력 시 앱 샘플을 중복 재생하지 않음
- 단음 30문제 / 4음×10세트 로직 유지

## GitHub에 올릴 파일

기존 저장소에서 다음을 교체하세요.

- `project.yml`
- `Sources/Info.plist`
- `Sources/SightReadingTrainerApp.swift`
- `Sources/notation.html`
- `.github/workflows/main.yml`
- `NOTICE.txt`

## 검증 범위

정적 검사와 빌드 단계 자동 검증을 넣었지만, 최종 IPA의 실제 iPad 화면 렌더링과 스피커 음정은 실제 기기 설치 후 마지막으로 확인해야 합니다.
