# 성능 검수 리포트 — Increment 5 (화면 3 "색칠 캔버스" · PencilKit/Canvas 드로잉 · 디바운스 저장 · ImageRenderer 썸네일)

대상: `/Users/JD/workspace/jd-coloring/jdColoring/` 화면 3 신규/변경 .swift 파일
검수일: 2026-06-01
관점: iOS/macOS(SwiftUI) 성능 — 드로잉/렌더 비용(매 프레임 재그리기·블렌드 합성·라인아트 디코딩), 자동저장 디바운스·`ImageRenderer`/`PKDrawing.image` 메인스레드 합성, `progressData` 직렬화 누적, retain cycle/`[weak self]`, `@Query` predicate, representable 재생성과 `saver.flush` 재바인딩, 화면 이탈 flush 경합. 채색은 앱의 **핵심 경로**라 우선순위 가중.
방침: 코드 수정 없음. 진단·권고만. 실제 코드 라인 근거로만 판단. 불확실은 '확인 필요' 표기. 빌드는 macOS BUILD SUCCEEDED 상태(기능 버그가 아닌 성능 관점).

---

## 검수 대상 확인 (먼저 점검)

- **화면 3 진입**: `GalleryView.swift:99-101`의 `.navigationDestination(item: $selectedTemplate)`에서 `ColoringCanvasView(profile:template:)` 생성. 셀 탭(`openColoring`, `:254-256`) → `selectedTemplate` 설정 → push. 구조 확인.
- **레이어 구성**(`ColoringCanvasView.canvasCard`, `:91-114`): `Color.white` → `DrawingCanvas`(드로잉 표면) → `lineImage`(라인아트, `.blendMode(.multiply)` + `.allowsHitTesting(false)`) 의 ZStack을 `aspectRatio(...).clipShape(...).overlay(stroke).shadow(...)`로 감쌈. 확인.
- **플랫폼 분기**(`DrawingCanvas.swift:33-43`): iOS=`PencilCanvasRep`(UIViewRepresentable, PencilKit), macOS=`FallbackBrushCanvas`(SwiftUI `Canvas` 브러시). 확인.
- **저장 경로**: 드로잉 변경 → 1초 디바운스(`DispatchWorkItem`+`asyncAfter`) → `save()` → `CanvasThumb.render`(`ImageRenderer`) + 진행 데이터 인코딩 → `onPersist`(=`ColoringCanvasView.persist`, `:211-222`) → `existing` 갱신/`insert` + `context.save()`. 확인.
- **flush 핸들**: `CanvasSaver`(`DrawingCanvas.swift:10-12`) — `flush` 클로저를 representable이 `makeUIView`/`onAppear`에서 바인딩, 뒤로가기 버튼(`:75`)·`onDisappear`(`:55`)에서 호출. 확인.
- **@Query predicate**(`ColoringCanvasView.swift:22-29`): `init`에서 `persistentModelID` 비교로 `(profile, template)` 작업물 1개만 fetch. 확인.

---

## 총평

화면 3은 increment 4의 교훈을 일부 계승한다: `@Query`에 **predicate를 걸어 현재 (프로필×도안) 작업물만 fetch**(`ColoringCanvasView.swift:26-28`), 자동저장에 **1초 디바운스 + `DispatchWorkItem` 취소**(`canvasViewDrawingDidChange`, `scheduleSave`), 라인아트 오버레이의 `.allowsHitTesting(false)`로 터치 패스스루, PencilKit Coordinator의 `weak var canvas`와 `save()` 클로저의 `[weak self]`(`:141`) 등은 적절하다. iOS는 `PKCanvasView`의 내부 타일 렌더에 위임해 매 스트로크 전체 재그리기를 피한다.

다만 채색 핵심 경로에 **구조적 성능 위험이 여러 건** 뚜렷하다. (1) **macOS `FallbackBrushCanvas`의 `Canvas`가 매 프레임 누적 스트로크 전체를 다시 그린다**(`draw(strokes, ...)`, `:181`) — 드래그 중 `current`에 포인트가 무제한 누적(`onChanged { current.append }`, `:189`)되고, 스트로크가 쌓일수록 O(전체 스트로크·점) 재그리기로 드로잉이 점점 끊긴다(중간). (2) **`CanvasThumb.render`가 매 저장마다 `ImageRenderer`(@MainActor)로 흰배경+드로잉+라인아트(multiply)를 합성**하고, iOS는 그 직전에 `PKDrawing.image(from:scale:1)`로 캔버스 전체를 풀해상 래스터화(`:152`)한다 — 1초마다 메인스레드에서 두 번의 무거운 래스터/합성이 채색 중 발생(중간). (3) **`CanvasThumb.render`가 라인아트 `PlatformImage`를 매 저장마다 `Image(...).resizable()`로 합성**하는데 다운샘플 없이 풀해상 라인아트(`template.imageData`, increment 4 기준 1400px)를 multiply 합성한다(중간/메모리). (4) **macOS `progressData`가 스트로크 JSON 전체를 매 저장 인코딩**(`JSONEncoder().encode(strokes)`, `:237`) — 스트로크 누적 시 인코딩 Data가 선형 증가(중간). 그 외 라인아트 오버레이 매 렌더 multiply 합성(낮음), `saver.flush` 재바인딩과 onDisappear/뒤로가기 flush 중복(낮음), `recentColors`/`@Query existing` 접근(낮음/정보) 등이 남는다. 명백한 retain cycle은 없으나 macOS 폴백의 `save()` 클로저 캡처는 확인 필요.

---

## 발견 항목

### [중간] macOS `FallbackBrushCanvas`의 `Canvas`가 매 프레임 누적 스트로크 전체 재그리기 + 드래그 중 `current` 무제한 누적
- **위치**: `Views/Canvas/DrawingCanvas.swift:178-204`(body/Canvas/gesture), `:181`(`draw(strokes, in: &ctx)`), `:182-184`(`current` 그리기), `:189`(`onChanged { v in current.append(v.location) }`), `:213-225`(`draw`)
- **문제**:
  - macOS 폴백의 `Canvas` 클로저(`:180-185`)는 **매 무효화(프레임)마다 `draw(strokes, ...)`로 누적 스트로크 전체를 처음부터 다시 그린다.** 스트로크 N개·각 점 P개면 한 프레임당 O(N·P) 경로 구성·스트로크 연산이다. SwiftUI `Canvas`는 부분 갱신/레이어 캐시가 없어(전체 클로저 재실행) **이전에 그린 스트로크를 보존하지 못한다.**
  - 드래그 중에는 `DragGesture(minimumDistance: 0).onChanged { current.append(v.location) }`(`:188-189`)로 **`current` 배열이 손을 떼기 전까지 무한 누적**된다. `onChanged`마다 `@State current`가 바뀌어 `Canvas`가 재그려지고(`:182-184`에서 `current` 한 획 + `:181`에서 기존 전체), 한 획이 길수록 `current`의 점 수도 늘어 그 획 자체의 재그리기도 무거워진다. 즉 **"긴 한 획 × 이미 쌓인 많은 스트로크"** 조합에서 드로잉이 눈에 띄게 끊긴다.
  - 체크리스트의 "스트로크 N개 → O(N)/프레임" 그대로다. macOS는 검증·보조 경로(주석 `:161` "검증·Mac 사용용")라 영향이 iPad만큼 치명적이진 않으나, **Mac에서 실제 색칠 시 스트로크가 수십~수백 개로 쌓이면 체감**된다.
- **근거(언제 체감)**: Mac에서 한 그림에 색칠을 많이 쌓을수록(스트로크 누적), 그리고 한 획을 길고 빠르게 그을수록(`current` 점 누적). 드래그 중 매 `onChanged` 프레임에서 전체 + 현재 획 재그리기가 겹쳐 지연·끊김.
- **권고(방향만)**: macOS `Canvas`의 전체 재그리기를 줄이는 방향 검토 — (a) 이미 확정된 스트로크는 **별도 캐시 레이어/`drawingGroup` 또는 한 번 래스터화한 비트맵**으로 두고, 진행 중 `current` 한 획만 그 위에 덧그리기. (b) `current`에 점을 **거리 임계로 솎아 적재**(매 픽셀 이동마다 append하지 않음)해 점 수 폭증 억제. (c) 폴백이 어차피 보조 경로라면 스트로크 상한·단순화로 비용 상한을 두는 것도 방법. iOS `PKCanvasView`는 내부 타일 렌더라 해당 없음.

### [중간] `CanvasThumb.render`(ImageRenderer @MainActor) + iOS `PKDrawing.image(from:scale:)` 풀해상 래스터 — 1초마다 메인스레드 합성
- **위치**: `Views/Canvas/DrawingCanvas.swift:48-76`(`CanvasThumb.render`, `@MainActor`), `:66-67`(`ImageRenderer` + `scale = 2`), `:146-156`(iOS `save()`), `:152`(`cv.drawing.image(from: bounds, scale: 1)`), `:234-242`(macOS `save()`)
- **문제**:
  - `CanvasThumb.render`는 `@MainActor`(`:48`)이며 내부에서 **`ImageRenderer`로 ZStack(흰배경+base+라인아트 multiply)을 합성**(`:57-67`)한다. `ImageRenderer`는 메인스레드에서 SwiftUI 뷰 트리를 렌더하므로 **저장마다 메인 합성 비용**이 든다. `renderer.scale = 2`(`:67`)라 480pt 기준 산출이 960×960 근방 픽셀로 더 커진다.
  - iOS `save()`는 그 **직전에 `cv.drawing.image(from: bounds, scale: 1)`**(`:152`)로 캔버스 드로잉 전체를 풀해상 `UIImage`로 래스터화한다. 즉 한 번 저장에 **(1) PencilKit 드로잉 래스터화 + (2) ImageRenderer ZStack 합성 + (3) 라인아트 multiply** 의 무거운 메인 작업이 연쇄로 돈다.
  - 저장 트리거는 `canvasViewDrawingDidChange`(`:139-144`)가 1초 디바운스로 호출 → **색칠을 계속하는 동안 1초마다 1회씩** 이 합성이 메인에서 실행된다. 디바운스가 "변경이 멈춘 뒤 1초"가 아니라 매 변경마다 취소·재예약이므로, 손을 잠깐씩 떼며 칠하면 **떼는 순간마다 1초 뒤 합성이 누적적으로 발생**(빠른 연속 입력에선 합치지만, 간헐 입력에선 자주 터짐). 합성이 16ms를 넘으면(960px 합성+풀해상 멀티플라이는 충분히 가능) **그 프레임에 드로잉 입력 지연·히치**가 생긴다.
  - PencilKit은 입력 처리를 내부 최적화하지만, **`save()`의 래스터/합성은 우리 코드가 메인에서 돌리는 것**이라 그 보호를 못 받는다.
- **근거(언제 체감)**: 큰 캔버스(`bounds`가 화면의 대부분, `maxWidth: 900/maxHeight: 520` 카드)에서 색칠을 지속할 때, 1초 디바운스가 만료될 때마다 순간 히치. 라인아트가 클수록(아래 [중간]) 합성 비용 가중.
- **권고(방향만)**: (a) 썸네일 합성·인코딩을 **메인에서 최소화**하라 — 가능한 부분(JPEG 인코딩, 데이터 직렬화)은 백그라운드로 옮기고 메인엔 래스터 캡처만 남기는 분리 검토(단 `ImageRenderer`/`PKDrawing.image`는 메인 필요 — 캡처는 메인, 후처리는 off-main). (b) **저장 빈도 vs 비용 재설계**: 매 변경마다 재예약하는 1초 디바운스 대신, "마지막 저장 후 최소 간격(throttle)" 또는 "썸네일은 더 낮은 빈도/이탈 시에만, progressData만 자주" 로 분리. (c) 썸네일 `maxPixel`/`scale`을 표시 용도(갤러리 셀 ~200pt)에 맞춰 더 낮추는 것 검토(`scale = 2`·480px가 셀에 과대일 수 있음 — 확인 필요).

### [중간] `CanvasThumb.render`가 라인아트를 다운샘플 없이 풀해상 multiply 합성 — 저장마다 풀해상 디코딩·합성, 메모리
- **위치**: `Views/Canvas/DrawingCanvas.swift:60-62`(`Image(platform: lineart).resizable().blendMode(.multiply)`), 라인아트 출처 `ColoringCanvasView.swift:53`(`PlatformImage(data: template.imageData)`), `:99`(`lineart: lineImage`)
- **문제**:
  - `render`의 ZStack에 들어가는 `lineart`는 `ColoringCanvasView`의 `lineImage = PlatformImage(data: template.imageData)`(`:53`)다. increment 4 기준 `template.imageData`는 **색칠용 풀해상(~1400px) 이미지**다(그리드용 `thumbnailData`와 분리된 큰 쪽). 이를 `Image(...).resizable().blendMode(.multiply)`로 **다운샘플 없이** ZStack에 올려 480pt 프레임에 렌더한다(`:60-64`).
  - `ImageRenderer`가 multiply 합성하려면 **풀해상 라인아트 비트맵을 디코딩·합성에 동원**한다. 저장은 1초마다(위 [중간]) 반복되므로, 그때마다 풀해상 라인아트가 합성 파이프라인에 올라간다. `lineImage`는 `@State`로 한 번 디코딩해 보관(`:52-54`)하니 재디코딩은 아니나(좋음), **합성 시 풀해상 픽셀을 480pt로 다운스케일하는 비용**은 매번 든다.
  - **메모리**: `lineImage`(풀해상 `PlatformImage`)가 화면 3 생존 동안 상주(`@State`, `:19`). 동시에 `canvasCard`의 오버레이(`ColoringCanvasView.swift:103-107`)도 같은 `lineImage`를 화면에 multiply로 상시 표시한다 — 즉 **풀해상 라인아트가 (1) 화면 오버레이 상시 + (2) 저장 시 ImageRenderer 합성** 두 경로에서 쓰인다. 큰 이미지일수록 합성·표시 모두 무거워진다.
- **근거(언제 체감)**: 라인아트 원본이 클수록(고해상 사진 도안), 저장 시 합성 히치(위 [중간])가 커지고, 화면 오버레이 multiply 렌더도 무거워진다. 여러 도안을 오가며 색칠하면 풀해상 디코딩이 진입마다 반복(`onAppear` `:52-53`).
- **권고(방향만)**: 썸네일 합성·화면 오버레이에 쓰는 라인아트를 **표시 해상도에 맞춘 다운샘플본**으로 분리 검토(`ImageDownsampler` 패턴 재사용). 색칠 정합(좌표계)은 풀해상이 아니어도 `aspectRatio`로 맞춰지므로, 오버레이/썸네일용은 화면·썸네일 픽셀 상한으로 충분(확인 필요 — 라인 선명도 요구치). increment 4에서 "한 Data를 베이스·표시 겸용"을 분리한 것과 같은 방향이다.

### [중간] macOS `progressData`가 스트로크 JSON 전체를 매 저장 인코딩 — 스트로크 누적 시 인코딩·Data 선형 증가
- **위치**: `Views/Canvas/DrawingCanvas.swift:234-242`(macOS `save()`), `:237`(`JSONEncoder().encode(strokes)`), `:15-20`(`BrushStroke` 직렬화 모델), 비교 iOS `:151`(`cv.drawing.dataRepresentation()`)
- **문제**:
  - macOS `save()`는 **전체 `strokes`(누적 스트로크 배열)를 매번 통째로 `JSONEncoder`로 인코딩**한다(`:237`). `BrushStroke`는 `pts: [CGPoint]` + 색/굵기/지우개(`:15-20`)라, 점이 많은 긴 획·다수 스트로크가 쌓이면 JSON 문자열이 커지고 **인코딩 시간·산출 Data 크기가 스트로크 총량에 선형 비례**한다. 저장은 1초 디바운스로 반복되므로, 색칠 후반(스트로크가 많아진 상태)에는 매 저장이 점점 무거워진다(점진적 열화).
  - JSON은 CGPoint를 `{"x":..,"y":..}` 등 텍스트로 직렬화해 **이진 대비 부피가 크다.** 외부저장(`Artwork.progressData` `@Attribute(.externalStorage)`, `Artwork.swift:17`)이라 DB 인라인 폭증은 피하나, 매 저장 디스크 쓰기 본문이 커진다.
  - iOS는 `PKDrawing.dataRepresentation()`(`:151`)로 PencilKit 최적화 이진을 쓰므로 상대적으로 가볍다 — **macOS 폴백에만 해당하는 비용**이다(보조 경로라 치명도는 낮으나 누적 열화가 분명).
  - 위 [중간] "Canvas 전체 재그리기"와 **같은 `strokes` 누적이 원인**이라 두 비용이 같은 방향으로 함께 커진다.
- **근거(언제 체감)**: Mac에서 한 도안에 색칠을 많이 쌓을수록 저장 1초마다 인코딩이 무거워지고 progressData가 커짐. 다시 들어와 디코딩(`:197` `JSONDecoder().decode([BrushStroke])`)할 때도 비용 증가.
- **권고(방향만)**: macOS 진행 데이터 형식을 **이진/델타**로 검토 — (a) 전량 재인코딩 대신 마지막 저장 이후 추가분만 append하는 방식, 또는 (b) `PropertyListEncoder(.binary)`/커스텀 이진으로 부피·인코딩 시간 절감, (c) 점 솎기(위 [중간] (b))로 `pts` 수 자체를 줄이면 인코딩·드로잉 양쪽이 동시 완화. macOS가 검증용 보조라면 우선순위는 iPad 항목 다음.

### [낮음] 라인아트 오버레이 `.blendMode(.multiply)` 화면 상시 합성 — 드로잉 중 매 렌더 합성
- **위치**: `Views/ColoringCanvasView.swift:103-107`(`image.resizable().scaledToFit().blendMode(.multiply).allowsHitTesting(false)`), 카드 컨테이너 `:91-113`
- **문제**:
  - `canvasCard`는 드로잉 표면 위에 라인아트를 **`.blendMode(.multiply)`로 상시 오버레이**한다(`:103-107`). 블렌드 모드는 GPU 합성 단계에서 **오프스크린/혼합 합성**을 요구할 수 있어, 드로잉으로 하위 레이어가 갱신될 때마다 multiply 합성이 재평가된다. `.allowsHitTesting(false)`(`:106`)로 터치는 패스스루(좋음)지만 **렌더 합성 비용은 남는다.**
  - 라인아트가 풀해상(위 [중간])이고 카드가 큰 영역(`maxWidth: 900/520`)이라, multiply 합성 픽셀 수가 많다. iOS `PKCanvasView`가 입력은 최적화해도, 그 위에 얹힌 SwiftUI multiply 오버레이 합성은 별개 경로다. 다만 라인아트는 정적(드로잉 중 안 바뀜)이라 SwiftUI/Metal이 캐시할 여지가 있어(확인 필요) **드로잉 자체보다는 영향이 작을 가능성** — [낮음]으로 둔다.
  - 정합성(성능 외): 오버레이는 `scaledToFit`(`:104`)인데 드로잉 좌표계/썸네일 합성은 `bounds`/`aspect` 기준이라, **라인아트와 색칠 정렬**이 카드 비율과 어긋날 여지 — 성능 아닌 정합성은 '확인 필요'.
- **근거(언제 체감)**: 큰 카드 + 풀해상 라인아트에서 빠르게 색칠할 때 합성 부하. 정적 캐시가 들으면 미미.
- **권고(방향만)**: 라인아트 오버레이를 **다운샘플본**(위 [중간])으로 바꿔 합성 픽셀 수를 줄이고, 정적 레이어임을 활용해 `drawingGroup`/별도 캐시로 매 프레임 재합성을 피하는지 계측·검토. 정합성(좌표계 vs scaledToFit)은 실기기 정렬 확인 필요.

### [낮음] `saver.flush` 재바인딩 + onDisappear/뒤로가기 flush 중복 — 경합·중복 저장 여지
- **위치**: `Views/Canvas/DrawingCanvas.swift:115`(`makeUIView`에서 `saver.flush = { ...save() }`), `:120-124`(`updateUIView`는 flush 재바인딩 안 함), macOS `:200`(`onAppear`에서 `saver.flush = { save() }`), 호출부 `ColoringCanvasView.swift:55`(`.onDisappear { saver.flush() }`), `:75`(뒤로가기 `Button { saver.flush(); dismiss() }`)
- **문제**:
  - **iOS**: `saver.flush`는 `makeUIView`에서 1회 바인딩되고(`:115`) `updateUIView`에선 재바인딩하지 않는다(`:120-124`). representable이 재생성(예: `@State`가 아닌 부모 변화로 makeUIView 재호출)되면 새 Coordinator/`save`로 다시 묶이나, 일반적으론 makeUIView 1회라 안정적이다(좋음). `CanvasSaver`가 `@State`(`ColoringCanvasView.swift:20`)라 뷰 갱신에도 인스턴스가 안정 — flush가 항상 유효한 Coordinator를 가리키는지는 makeUIView 시점 캡처에 의존(확인 필요 — Coordinator 교체 시 옛 클로저 잔존 가능성).
  - **뒤로가기 + onDisappear 중복**: 뒤로가기 버튼이 `saver.flush(); dismiss()`(`:75`)를 호출하고, 그 dismiss로 `onDisappear`(`:55`)가 또 `saver.flush()`를 호출한다 — **flush가 짧은 간격에 2번** 실행될 수 있다. `save()`는 진입부에 `pending?.cancel()`(`:147`, `:235`)을 두어 디바운스와의 경합은 막지만, **연속 2회 flush는 둘 다 실제 합성·인코딩·`context.save()`를 수행**할 수 있어(가드는 "비었으면 return"뿐, `:150`/`:236`) 이탈 순간 무거운 저장이 두 번 일어날 여지가 있다. 둘째 호출도 같은 strokes/drawing이라 결과는 동일(데이터 정합성은 무해)하나 **비용 중복**이다.
  - 디바운스 `pending`과 flush의 경합 자체는 `pending?.cancel()`로 정리돼 있어 안전(좋음).
- **근거(언제 체감)**: 뒤로가기로 이탈할 때마다 무거운 썸네일 합성(위 [중간])이 최대 2회. 큰 캔버스/라인아트면 이탈이 살짝 무거워짐.
- **권고(방향만)**: flush를 **중복 호출 안전**하게(이미 최신이면 즉시 return하는 더티 플래그, 또는 뒤로가기에서 `dismiss`만 하고 flush는 `onDisappear` 한 곳으로 일원화) 정리 검토. Coordinator 교체 시 옛 flush 클로저 유효성은 `updateUIView`에서 재바인딩 또는 약참조 경유로 확인 필요.

### [낮음/정보] retain cycle / `[weak self]` / 클로저 캡처 — iOS 적정, macOS 폴백 캡처 확인 필요
- **위치**: iOS `DrawingCanvas.swift:134`(`weak var canvas`), `:141`(`DispatchWorkItem { [weak self] in self?.save() }`), `:115`(`saver.flush` 클로저가 `context.coordinator` 캡처), macOS `:229`(`DispatchWorkItem { save() }` — `[weak self]` 없음), `:200`(`saver.flush = { save() }`)
- **문제**:
  - **iOS**: Coordinator의 `pending` 작업이 `[weak self]`(`:141`)라 디바운스 작업이 Coordinator를 강참조하지 않는다(좋음). `canvas`는 `weak`(`:134`). `saver.flush` 클로저(`:115`)는 `context.coordinator`를 강참조하나, `CanvasSaver`는 `@State`로 뷰가 보유하고 Coordinator는 representable이 보유 — **`CanvasSaver` → Coordinator 강참조 경로**가 생긴다. 둘의 수명이 화면 3과 함께 끝나면(이탈 시 해제) 누수는 아니나, **flush 클로저가 Coordinator를 잡고 있어 Coordinator 해제가 `CanvasSaver`/뷰 해제에 묶인다**(확인 필요 — `@State` `saver`가 뷰와 함께 해제되면 함께 풀림). 명백한 영구 순환은 아님.
  - **macOS**: `FallbackBrushCanvas`는 `struct`(값 타입 View)라 `save()`/`scheduleSave`의 `DispatchWorkItem { save() }`(`:229`)·`saver.flush = { save() }`(`:200`) 클로저가 **`self`(View 값)와 그 `@State`를 캡처**한다. 값 타입이라 전통적 강참조 순환은 아니나, SwiftUI `@State`는 뷰 밖 저장소에 있어 **클로저가 캡처한 View 값의 `@State` 접근이 항상 최신/유효한지**는 확인 필요(특히 `asyncAfter`로 지연 실행되는 작업이 캡처한 옛 View 값의 `strokes`/`canvasSize`를 읽는지). 디바운스 만료 시 `strokes`가 클로저 캡처 시점 값일 수 있어 **정합성(최신 strokes 누락)** 여지 — '확인 필요'.
- **근거**: iOS `[weak self]`·`weak canvas` 명시(좋음). macOS는 값 타입이라 누수는 아니나 `@State` 캡처 의미가 미묘.
- **권고(방향만)**: iOS는 현행 적정. macOS 폴백의 지연 클로저가 **항상 최신 `@State`를 읽도록**(SwiftUI는 보장하나, `DispatchWorkItem` 캡처는 일반 Swift 캡처라 주의) 동작 확인 권장 — 특히 `save()`가 캡처 시점이 아닌 실행 시점의 `strokes`를 쓰는지. 누수 측면은 이상 없음.

### [낮음/정보] `@Query` predicate(`persistentModelID` 비교) · `existing` 접근 빈도 · `@State saver` 안정성 — 적정
- **위치**: `ColoringCanvasView.swift:22-29`(`init`의 `#Predicate` `persistentModelID` 비교), `:31`(`existing { artworks.first }`), `:95`(`existing?.progressData`), `:212`(`persist`에서 `existing`), `:20`(`@State saver`)
- **문제 아님(정보, 강점) + 참고**:
  - **predicate 적정**: increment 4 권고대로 `@Query`에 predicate를 걸어 **(profile×template) 작업물만 fetch**(`:26-28`). 관계 직접 비교가 predicate 미지원이라 `persistentModelID` 비교로 우회 — increment 4와 일관(좋음). 전체 fetch 후 클라이언트 필터 대비 가볍다.
  - **`existing` 접근**: `existing`은 computed(`:31` `artworks.first`)지만 `artworks`가 predicate로 **0~1개로 좁혀져** 있어 `.first` 비용은 사실상 상수. body 경로 접근(`:95` `existing?.progressData`)은 representable 인자 평가 시점 — `progressData`(외부저장 Data) 접근이 매 body마다 발생하면 **외부저장 본문 로드 비용**이 있을 수 있으나(확인 필요 — 외부저장 지연 로드/캐시 여부), 0~1개라 increment 4의 전체 순회 같은 곱셈 비용은 없다(좋음).
  - **`@State saver` 안정성**: `CanvasSaver`가 `@State`(`:20`)라 뷰 갱신 간 **인스턴스가 안정**(재생성 안 됨) — flush 바인딩이 유지된다(좋음). representable 재생성과의 관계는 위 [낮음] flush 항목 참조.
- **근거**: `:26-28` predicate, `:31`/`:95` 좁혀진 `artworks`, `:20` `@State saver`.
- **권고(방향만)**: 현행 유지(좋음). `existing?.progressData`가 body마다 외부저장 본문을 로드하는지만 확인(필요 시 `onAppear`에서 1회 읽어 `@State` 보관 검토).

### [낮음/정보] `ColorPaletteGrid`(72색) · `recentColors` · dock 브러시/색 — 렌더 경량
- **위치**: `Views/Components/ColorPaletteGrid.swift:19-32`(8×9=72 `swatch`), `DesignSystem/Palette.swift:6-18`(상수 + `all` computed flatten), `ColoringCanvasView.swift:123`(`recentColors.prefix(6)`), `:144-153`(브러시 굵기), `:203-209`(`pick`)
- **문제 아님(정보) + 참고**:
  - `ColorPaletteGrid`는 72개 `Circle().fill`을 `ForEach`로 그리나(`:19-26`), **팝오버가 열렸을 때만**(`ColoringCanvasView.swift:50` `if paletteOpen`) 실체화돼 상시 비용 아님(좋음). `id: \.offset`(`:20/:22`)은 정적 색 배열이라 안전(고정 순서).
  - `Palette.all`은 computed로 `rows.flatMap`(`Palette.swift:18`)이나 화면 3 핫패스에서 호출되지 않음(`defaultColor`/`brushWidths` 상수 사용, `ColoringCanvasView.swift:14-15`) — 무해.
  - `recentColors`는 `prefix(6)`로 상한(`:123/:208`), `pick`은 O(6) — 경량. dock는 정적 위젯이라 드로잉 핫패스와 분리.
  - `Palette.rows`는 `static let`이나 클로저 `.map { $0.map { Color(hex:) } }`(`:15`)로 **타입 최초 접근 시 1회 평가**돼 72색 생성 — 진입 시 1회, 무해.
- **근거**: `ColorPaletteGrid.swift:19-26` 조건부 실체화, `Palette.swift` 상수.
- **권고(방향만)**: 없음(경량). 팔레트가 매우 자주 열고닫히면 `swatch` 뷰 경량 유지 정도.

### [낮음/정보] 자동저장 디바운스(1초) 설계 · `DispatchWorkItem` 취소 정확성 — 정확, 빈도만 점검
- **위치**: iOS `DrawingCanvas.swift:139-144`(`canvasViewDrawingDidChange`), `:147`(`save()` 진입 `pending?.cancel()`), macOS `:227-232`(`scheduleSave`), `:235`(`save()` 진입 cancel)
- **문제 아님(정보, 강점) + 참고**:
  - 디바운스 패턴 자체는 정확하다: 변경마다 `pending?.cancel()` 후 새 `DispatchWorkItem`을 1초 뒤 예약(`:140-143`/`:228-231`), `save()` 진입에서도 `pending?.cancel()`(`:147`/`:235`)로 **flush와 예약 저장의 경합을 차단**(좋음). 취소 정확성 양호.
  - **빈도 점검**: 매 변경마다 재예약이라 "연속 입력 중엔 안 터지고, 멈춘 뒤 1초에 1회"가 이상이나, 색칠은 짧은 획을 반복하는 패턴이라 **획 사이 1초 공백마다 저장이 터질 수 있다.** 저장 1회 비용이 무거운 위 [중간](합성/래스터/인코딩)과 곱해지면 체감 — 디바운스 자체보다 **저장 1회 비용**이 핵심.
  - `save()`의 가드(`bounds>1`, `!strokes.isEmpty` 등 `:150`/`:236`)로 빈 저장 방지(좋음).
- **근거**: `:140-143`/`:228-231` 재예약, `:147`/`:235` 진입 취소.
- **권고(방향만)**: 디바운스 로직은 유지. 단 위 [중간]대로 **저장 1회 비용을 낮추거나** 썸네일/progressData 저장 빈도를 분리(예: progressData는 자주, 썸네일은 이탈/저빈도)하면 간헐 입력에서의 누적 부하가 줄어든다.

---

## 메인 스레드 / 메모리 / retain cycle 점검 결과 (increment 5 관점)

- **메인 스레드 무거운 연산**: 핵심은 **`save()`의 메인 합성·래스터·인코딩**(위 [중간] 2건) — `ImageRenderer`(@MainActor) + iOS `PKDrawing.image(from:scale:)` + 풀해상 라인아트 multiply + (macOS) 전체 JSON 인코딩이 1초 디바운스마다 메인에서 연쇄. 추가로 macOS `Canvas` 전체 재그리기가 드래그 중 메인 프레임에 실림(위 [중간]).
- **메모리**: `lineImage`(풀해상 `PlatformImage`)가 화면 3 생존 동안 상주 + 저장 합성·화면 오버레이 두 경로에서 풀해상 사용(위 [중간]/[낮음]). macOS `strokes`/`progressData`가 색칠 누적에 따라 선형 증가(위 [중간]). 도안을 오갈 때마다 풀해상 라인아트 재디코딩(`onAppear`).
- **retain cycle / `[weak self]`**: iOS Coordinator의 `pending`이 `[weak self]`, `canvas`가 `weak`(좋음). `saver.flush`가 Coordinator를 강참조하나 화면 수명과 함께 풀림(영구 순환 아님, 확인 필요). macOS는 값 타입 View 캡처라 누수 아님 — 단 지연 클로저의 `@State` 캡처 의미는 확인 필요.
- **불필요/중복 저장**: 뒤로가기 `flush` + `onDisappear` `flush` 2회 호출 여지(위 [낮음]) — 비용 중복(데이터는 무해). 디바운스 vs flush 경합은 `pending?.cancel()`로 차단(좋음).
- **SwiftData**: `@Query` predicate로 (profile×template) 1개만 fetch(increment 4 권고 계승, 좋음). `existing` 0~1개라 접근 경량. `existing?.progressData`의 외부저장 본문 로드 빈도만 확인 필요.
- **드로잉/렌더**: iOS `PKCanvasView`는 입력·렌더 내부 최적화(좋음) — 우리 부하는 오버레이 multiply와 `save()`. macOS `Canvas`는 매 프레임 전체 재그리기로 스트로크 누적 시 열화(핵심 위험, 단 보조 경로).

---

## 심각도별 개수 요약

| 심각도 | 개수 | 항목 |
|--------|------|------|
| 높음 | 0 | — |
| 중간 | 4 | macOS `Canvas` 매 프레임 누적 스트로크 전체 재그리기 + `current` 무제한 누적 / `CanvasThumb.render`(ImageRenderer)+`PKDrawing.image` 1초마다 메인 합성 / 라인아트 다운샘플 없는 풀해상 multiply 합성(저장·오버레이) / macOS `progressData` 스트로크 JSON 전체 매 저장 인코딩(누적 선형 증가) |
| 낮음 | 5 | 라인아트 오버레이 `.multiply` 화면 상시 합성(정보) / `saver.flush` 재바인딩·이탈 flush 중복(경합) / retain cycle·`[weak self]`(iOS 적정·macOS 캡처 확인, 정보) / `@Query` predicate·`existing`·`@State saver`(정보·강점) / `ColorPaletteGrid`·`recentColors`·dock 경량(정보) / 디바운스 설계·취소 정확성(정보·강점) |
| **합계** | **4 중간 + 다수 낮음/정보** | |

> 중간 4건 중 3건(`Canvas` 재그리기, 라인아트 풀해상, macOS JSON 인코딩)은 **macOS 폴백/라인아트 해상도**에 몰려 있고, 가장 치명적인 iPad 핫패스 항목은 **`save()`의 메인 합성·래스터**다. 낮음 묶음은 강점/정보성(디바운스 정확성, predicate, retain cycle iOS)과 소규모 조치(flush 중복)가 섞여 있다.

## 가장 먼저 고칠 Top 3

1. **[중간] `save()`의 메인 합성·래스터 비용·빈도 재설계** (`DrawingCanvas.swift:48-76` `CanvasThumb.render`, `:146-156` iOS `save`/`:152` `PKDrawing.image`, 트리거 `:139-144`). 채색 **핵심 핫패스(iPad)** — 1초 디바운스마다 `ImageRenderer`(@MainActor) + 풀해상 드로잉 래스터 + 라인아트 multiply가 메인에서 연쇄로 돌아 색칠 중 히치 유발. 후처리(인코딩) off-main 분리, 썸네일 저빈도/이탈 시로 분리, `scale`/`maxPixel` 표시용 하향을 우선 검토.

2. **[중간] macOS `FallbackBrushCanvas`의 전체 재그리기·`current` 누적 억제** (`DrawingCanvas.swift:178-204`, `:181` 전체 draw, `:189` `current.append`). Mac에서 스트로크가 쌓일수록 매 프레임 O(N·P) 재그리기로 드로잉이 끊김. 확정 스트로크를 캐시 레이어/래스터로 분리하고 진행 획만 덧그리기, `current` 점 거리 솎기로 비용 상한. (보조 경로라 Top 1 다음.)

3. **[중간] 라인아트 풀해상 → 표시/썸네일용 다운샘플 분리** (`DrawingCanvas.swift:60-62` 합성, `ColoringCanvasView.swift:53` `template.imageData` 디코딩, `:103-107` 오버레이). 풀해상 라인아트가 (1) 저장 합성·(2) 화면 multiply 오버레이 양쪽에서 매번 동원돼 합성·메모리 부담. `ImageDownsampler` 패턴으로 표시·썸네일용 축소본을 분리하면 Top 1의 합성 비용과 [낮음] 오버레이 합성이 함께 완화(색칠 베이스 정합은 `aspectRatio`로 유지). macOS `progressData` JSON 인코딩(중간 4번째)은 보조 경로라 그다음.

---

## 이월 항목 검증

- **increment 4 [낮음] `@Query` predicate로 좁히기** — 화면 3 `ColoringCanvasView`에서 **계승 완료**(`:26-28` `persistentModelID` 비교 predicate). 전체 fetch + 클라이언트 필터 안티패턴 재발 없음(좋음).
- **increment 4 [중간] "한 Data를 베이스·표시 겸용" 분리 교훈** — 화면 3에서 **부분 재현**: `template.imageData`(풀해상)를 화면 오버레이·썸네일 합성에 그대로 겸용(위 [중간]). 표시용 다운샘플 분리가 같은 방향의 미완 과제.
- **increment 1~3 do/catch save · Task 취소 교훈** — `persist`의 `try? context.save()`(`ColoringCanvasView.swift:221`)는 **에러 무시(`try?`)**라 do/catch 로깅(increment 1~3 패턴) 대비 후퇴 — 저장 실패가 조용히 묻힘(정합성/디버깅, 성능 외 — '확인 필요'로 메모). 디바운스 `DispatchWorkItem` 취소는 정확(위 [낮음/정보], 좋음).
- **increment 1~2 디코딩 캐시(`ThumbnailCache`)** — 화면 3은 `lineImage`를 `@State`로 1회 디코딩 보관(`:52-53`)해 자체적으로 재디코딩을 피함(좋음). 다만 `ThumbnailCache`(다운샘플 없는 풀해상 캐시)는 화면 3 라인아트엔 미사용 — 표시용 다운샘플 도입 시 함께 정리 가능.

견고한 부분은 분명하다: `@Query` predicate로 작업물 1개만 fetch, 자동저장 디바운스 + `DispatchWorkItem` 취소의 정확성, iOS Coordinator의 `[weak self]`/`weak canvas`, `.allowsHitTesting(false)` 터치 패스스루, `@State saver` 인스턴스 안정성이 모두 적절하다. 핵심 개선은 **채색 핫패스(`save()`)의 메인 합성·래스터 비용을 낮추고 빈도를 분리**하는 것 — 여기에 라인아트 다운샘플 분리를 더하면 [중간] 다수가 동시에 완화된다. macOS 폴백(전체 재그리기·JSON 인코딩)은 보조 경로라 우선순위는 iPad 항목 다음. 불확실로 표기한 항목(`ImageRenderer` 실측 합성 시간, multiply 오버레이 정적 캐시 여부, `existing?.progressData` 외부저장 로드 빈도, macOS 지연 클로저의 `@State` 캡처 최신성, 라인아트/색칠 좌표계 정합)은 실기기·다수 스트로크 계측으로 확인 필요.
