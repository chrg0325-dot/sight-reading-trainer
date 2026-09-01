# 초견 트레이너 iPad v1.0

iPad 가로 전용 SwiftUI + Core MIDI 네이티브 앱입니다.

## 포함 기능
- 단음 30문제
- 4음 연속 40개 정답(10세트)
- 높은음자리표 / 낮은음자리표 / 둘 다
- C2~C6 문제 범위
- 샵/플랫
- 실제 MIDI Note On 입력
- 화면 가상 건반 입력
- PERFECT/GREAT/GOOD/OK/MISS 판정
- 점수, 콤보, 정확도, 평균 반응시간
- S/A/B/C 결과
- 개인 최고점
- 가로 전용 iPad UI

## GitHub Actions 빌드
이 ZIP의 내용물을 새 GitHub 저장소의 루트에 올리면,
`.github/workflows/build.yml`이 macOS runner에서 unsigned IPA를 생성합니다.

Artifacts:
`SightReadingTrainer-unsigned-IPA`

다운로드한 IPA는 Windows Sideloadly에서 본인 Apple ID로 서명하여 iPad에 설치할 수 있습니다.

## 주의
현재 버전의 오선지는 SwiftUI Canvas로 직접 그립니다.
실제 M115 USB MIDI 연결은 케이블 도착 후 실기기에서 최종 검증해야 합니다.
