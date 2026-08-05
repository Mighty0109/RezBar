# RezBar r1 — 메뉴바 해상도 전환 앱 초기 구현

날짜: 2026-08-05
Size: large (설계 확정 상태로 수령, 9단계 구현만)
실행: 투투

## Spec

메뉴바에서 디스플레이별 해상도·HiDPI·리프레시레이트를 전환하는 macOS 앱. 클린룸 구현
(기존 앱 코드·에셋·문구 참조 없음). Swift 5 언어 모드 / AppKit / macOS 14.0 / LSUIElement /
ad-hoc 서명 / xcodegen. 완료 기준 A1~A6은 위임 명세 그대로.

확정 스펙 중 변경 금지 항목: AppKit `menuWillOpen` 전체 재구성 구조, dedup 키 =
(ptW, ptH, pxW, pxH, rate 2자리 반올림), 정렬 = 면적 desc → HiDPI 먼저 → rate desc,
rate 표기 = `|rate−round(rate)| < 0.05`면 정수 아니면 소수 1자리, `.permanently`,
CG 목록이 디스플레이 정본.

## Decisions

### 1. 스펙 이견 1건 — A2 ④의 `47.95 → "47.9 Hz"` 기대값 (보고 필요)

명세는 rate 표기 테스트 기대값으로 `47.95 → "47.9 Hz"`를 열거했으나, **명세가 준 공식을
그대로 적용하면 리터럴 `47.95`는 `"48 Hz"`가 나온다.** 손계산이 아니라 실행으로 확인:

- Double `47.95`의 실제 저장값 = 47.95000000000000284…, `|47.95 − 48| = 0.04999999999999716`
  → 임계 0.05 **미만** → 정수 경로 → `"48 Hz"`
- 이 기계가 실제로 보고하는 값 = `47.94999694824219`, `|… − 48| = 0.0500030517578125`
  → 임계 **이상** → 소수 경로 → `"47.9 Hz"`

즉 명세의 의도(47.95Hz 모드는 "47.9 Hz"로 표기)는 **실 하드웨어 값에서 성립**하고, 리터럴
47.95에서만 부동소수점 경계 때문에 뒤집힌다. 공식은 "변경 금지"이고 기대값은 "공식에서 산출"이
규칙이므로 **공식을 그대로 두고**:

- 실 하드웨어 값 `47.94999694824219` → `"47.9 Hz"`를 테스트로 박음 (명세 의도 충족)
- 리터럴 `47.95` → `"48 Hz"`를 별도 경계 테스트(`testFormatRateAtExactThreshold`)로 박고,
  왜 그런지 주석에 기록. 공식이 바뀌면 이 테스트가 깨져 드러남

판단 필요: 공식을 유지할지(현재), 아니면 임계를 `<= 0.05`나 `< 0.0501`로 바꿔 리터럴
47.95도 "47.9"가 되게 할지. 실사용 값은 항상 하드웨어가 주는 47.9499…라 **현재 동작으로
실 UI에는 영향 없음** — 그래서 임의 변경하지 않고 보고만 함.

부수 효과(공식대로): `29.97 → "30 Hz"`, `23.976 → "24 Hz"`. NTSC 계열 rate가 정수로
뭉개지지만 이것도 명세 공식의 직접 귀결이라 그대로 두고 테스트로 박음.

### 2. `@main` + storyboard 없음 = 앱이 조용히 죽어 있음 (실버그, A5에서 포착)

A5(앱 실행 후 생존 확인)는 `pgrep`만 보면 PASS였다. 실제로는 **메뉴바에 아이콘이 안 떴다.**
menu bar 스크린샷 차분(앱 on/off 비교)으로 부재를 확인하고, `AppDelegate`에 stderr 진단을
넣어 재빌드해보니 **`init`조차 호출되지 않았다.**

원인: `@main`을 `NSApplicationDelegate` 채택 클래스에 붙이면 AppKit이 제공하는 기본
`main()`이 `NSApplicationMain` 경로를 타는데, 이 경로는 **MainMenu nib에서 델리게이트를
읽어 꽂는다.** RezBar는 storyboard·nib이 없으므로 `NSApp.delegate`가 nil로 남고 →
`applicationDidFinishLaunching` 미호출 → `MenuController` 미생성 → 상태 아이템 없음.
프로세스는 런루프를 돌기 때문에 **생존 체크는 통과한다** (A5가 단독으론 못 잡는 클래스).

해결: `AppDelegate`에 `static func main()`을 직접 정의해 `@main`이 그걸 쓰게 함
(NSApplication 생성 → delegate 대입 → `.accessory` → `run()`). `@main` on AppDelegate와
"storyboard 없음"이라는 명세 결정을 둘 다 유지하는 최소 변경. nib 추가나 `main.swift` 분리는
명세를 건드리므로 택하지 않음.

검증: 수정 후 재빌드 → 메뉴바 차분 재촬영에서 display 아이콘 출현 확인.

### 3. 메뉴 구성 경로를 헤드리스로 실행해 검증

네이티브 UI라 렌더 자동 검증이 불가하다는 게 명세 전제였으나, `MenuController.menuWillOpen(_:)`이
프로토콜 메서드라 **새 `NSMenu`를 넘겨 직접 호출**할 수 있었다. 실 디스플레이 데이터로 메뉴를
짓고 항목을 덤프하는 검사 바이너리를 만들어 실행 (스크래치패드, 커밋 안 함):
top-level 25개(해상도 22 + 구분선 + 로그인 + 종료), 체크마크 정확히 1개(현재 모드),
모드 항목 132개 전부 `representedObject` 보유, 누락 0. 클릭이 조용히 no-op 되는 클래스를
사전 배제.

### 4. 모드 필터링 안 함

`isUsableForDesktopGUI()`로 거르지 않는다. 명세에 필터 규칙이 없고, README가 요구한 경고
("비표시 모드 선택 시 화면 꺼질 수 있음")는 그런 모드가 목록에 있다는 전제에서만 성립하므로.

### 5. 색심도 관련 API 미사용

`pixelEncoding`은 deprecated이고 현행 하드웨어에서 전 모드 동일값이라 dedup 키에서 제외
(명세 지시와 동일). 실측: 이 기계에서 dedup 전 132 → 후 132로 **키 충돌 0건** — dedup은
방어적으로만 동작. 과거 중복의 출처였던 색심도 변종이 더는 안 나온다는 뜻.

### 6. 정렬에 결정성 타이브레이커 추가

명세 3규칙(면적 → HiDPI → rate)만으로는 전순서가 안 되고 Swift `sort`는 불안정이라 출력이
비결정적일 수 있다. 3규칙 **뒤에** ptW → pxW → pxH desc를 덧붙여 전순서로 만듦. 명세 규칙의
우선순위는 그대로.

또한 그룹핑은 "정렬된 배열에서 같은 키가 인접" 가정을 쓰지 않고 **최초 등장 순서 기준 버킷팅**으로
구현했다. 면적이 같고 모양이 다른 두 해상도(예: 1920×1080 vs 2160×960)가 규칙 1~3 아래에서
서로 끼어들 수 있기 때문.

### 7. `.xcodeproj`는 gitignore

`project.yml`이 정본인 xcodegen 표준 워크플로. README에 `xcodegen generate` 절차 명시.

### 8. 테스트 타깃 `GENERATE_INFOPLIST_FILE: YES`

xcodegen 기본 설정만으론 테스트 번들에 Info.plist가 없어 코드사인 단계에서 빌드 실패
(`does not have an Info.plist file`). 테스트 타깃에만 자동 생성 활성화.

## Trade-offs

- **rate 표기 공식 유지 vs 경계 보정**: 유지 선택. 실 하드웨어 값에선 의도대로 동작하고,
  공식은 "변경 금지" 항목이라 임의 수정이 더 위험. 대신 경계를 테스트로 박아 가시화. (결정 1)
- **`static main()` 직접 정의 vs nib 추가**: 전자 선택. 후자는 "storyboard 없음" 명세 위반이고
  nib 유지비용이 붙는다. 단점은 AppKit 기본 진입 경로에서 벗어나 낯설다는 것 — 주석으로 이유를
  길게 남겨 상쇄. (결정 2)
- **모드 미필터링**: 목록 완전성을 얻고 외장 디스플레이 블랙아웃 위험을 감수. 자동복귀
  카운트다운은 범위 밖이라 README 경고로만 커버. 외장 디스플레이 실사용 후 재검토 후보.
- **헤드리스 메뉴 검사 바이너리 미커밋**: 일회성 검증 도구라 유지비용(2관문) 대비 가치가 낮다고
  판단. 재현 절차는 이 문서에 남김. 정기적으로 필요해지면 그때 `Scripts/`로 승격.
- **테스트가 `ModeLogic`에 집중**: `DisplayManager`·`MenuController`는 CG/AppKit 의존이라
  유닛테스트 대신 probe(A3·A4)와 헤드리스 실행으로 커버. 경계 타입 변환 덕에 로직은 전부 순수
  함수 쪽에 있어 커버리지 손실이 작음.

## Touched

신규 (전부 이 작업에서 생성):

| 파일 | 역할 |
|---|---|
| `project.yml` | xcodegen 정의 (앱 + 테스트 타깃 + 스킴) |
| `Sources/ModeInfo.swift` | 값 타입 · dedup/group 키 · 그룹·플랜 모델 |
| `Sources/ModeLogic.swift` | 순수 로직 (dedup·정렬·표기·그룹핑·플랜) |
| `Sources/DisplayManager.swift` | CoreGraphics 경계 (열거·이름·전환) |
| `Sources/MenuController.swift` | NSStatusItem · menuWillOpen 재구성 |
| `Sources/AppDelegate.swift` | 진입점 (`static main()`) · SMAppService |
| `Support/Info.plist` | xcodegen 생성 (LSUIElement) |
| `Tests/ModeLogicTests.swift` | 유닛테스트 39개 |
| `Scripts/probe.swift` | CLT swift 단독 프로브 (열거 / `--switch`) |
| `README.md` · `LICENSE` · `.gitignore` | 배포 문서 |

## Follow-ups

1. **rate 표기 경계** — 싸리·마이티가 공식 유지 여부 판정 (결정 1). 실 UI 영향은 없음.
2. **외장 디스플레이 미검증** — 이 기계는 내장 1개뿐이라 서브메뉴 분기(디스플레이 2개 이상)는
   합성 fixture 테스트로만 확인됨. 실기 검증 대기.
3. **`docs/screenshot.png` 없음** — README가 참조하는 스크린샷 자리 비어 있음. 실기 확인 때 촬영.
4. **SMAppService 로그인 토글 미검증** — `/Applications` 복사 후에만 정상 동작해 빌드 폴더에선
   확인 불가. 마이티 실기 체크리스트 항목.
5. **`.requiresApproval` 분기 미실행** — 승인 대기 상태를 만들어보지 못함. 코드 경로만 존재.
6. 앱 아이콘 아트워크 없음 (범위 밖, 제네릭 허용).

## Skills used

없음. (기존 하네스 규칙 — discipline 6단계, Verification Loop, decisions 기록 — 만 적용)
