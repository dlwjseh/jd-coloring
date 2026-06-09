# 검수 리포트: Increment 8 — 한글 글리프 룩 v2 튜닝

## 반영 결과 (2026-06-09, 개발자) — 빌드 SUCCEEDED
- **M-1 (라운딩 자기교차 → 채색 영역 손실): 검증으로 해소(코드 변경 없음).** 추측 대신 24자 전부를 앱과 동일 로직(roundedCorners+draw)으로 512px 렌더 후 **flood-fill 영역 연결성**을 측정 → **전 글자 외곽선이 닫혀 enclosed 영역 ≥1**(ㄱ~ㅣ 모두 OK, ㅁ:2=고리띠+가운데구멍, ㅇ:2, ㅎ:4 등 기대치 일치). factor 0.18·0.14 동일 통과. ⇒ RegionPaintEngine 영역 분할에 문제 없음을 입증, 사용자 요청대로 더 둥근 **0.18 유지**. (정점별 변-절반 클램프가 직각 모서리에서 마주보는 획 폭도 사실상 제한 — 사각/스템 글자에서 교차 미발생.) **폰트 교체 시 동일 검증 재수행 필요(확인 항목).**
- **M-2 (closeSubpath/정점 처리 비일관): 반영.** ① 라운딩 게이트를 `s.closed || 시작≈끝(geomClosed)` 으로 변경(열린 윤곽은 폐곡선 라운딩 제외). ② `dedupAdjacent` 추가 — 인접+시작/끝 중복 정점 일반 제거(0길이 변 방지). ③ 파서에서 `move` 선행 없는 세그먼트(`cur.has==false`)는 무시 → 가짜 `(0,0)` 정점 혼입 차단. 하드닝 후 24자 재검증 동일 통과(회귀 0).
- **m-3 (순회 중 delete): 반영.** regen 삭제를 `let toDelete = album.templates.filter{...}` 스냅샷으로 떠서 삭제(의도 명시).
- **m-1·m-2 (minor "이상 없음"), n-1·n-2 (nit): 조치 불필요.** n-2의 "store 저장 후 UserDefaults set 직전 종료 시 1회 헛 재생성"은 무손상·1회성이라 보류(선택 최적화).

---

검수 대상: `HangulGlyphRenderer.swift`(전면 개편), `HangulSeeder.swift`(렌더 버전 도입), 호출부(`jdColoringApp.swift:103`, `AlbumCarouselView.swift:90`), 채색 호환(`RegionPaintEngine.swift`).
빌드 `** BUILD SUCCEEDED **` 전제. 판정은 실제 코드 근거로만, 실측 필요 항목은 "확인 필요"로 표시.

결론: **blocker 0, major 2, minor 3, nit 2.** 메인 블로킹/0회 단축은 회귀 없음. 정확성에서 라운딩 알고리즘 견고성 결함 2건(M-1 자기교차·M-2 닫힘처리)이 채색 영역 분할에 영향 줄 수 있어 우선 점검 필요.

---

## MAJOR

### M-1. `roundedPolygon` 라운딩이 가는 획에서 **윤곽 자기교차/뒤집힘** 유발 가능 — 채색 영역 손실 위험
- 위치: `Utilities/HangulGlyphRenderer.swift:101-125` (`roundedPolygon`), `:73-74`(R 산출)
- 문제: R은 path **전체 bounding box**의 짧은 변 × 0.18로 정해진다(`min(bb.width, bb.height) * factor`). 하지만 ㄱ·ㄴ·ㅁ·ㅏ 같은 자모의 "획 두께(stroke 폭)"는 글리프 bbox의 짧은 변보다 훨씬 작다. 정점별로 `min(R, dist(prev,c)/2, dist(c,next)/2)`로 변 길이의 절반까지는 클램프하지만, 이는 **변 방향(길이)** 만 보고 **마주보는 획의 폭(법선 방향 간격)** 은 전혀 고려하지 않는다. 획 폭이 2R보다 얇은 가는 획(예: ㅁ의 가로획, ㅏ의 곁줄기)에서는 한 변에서 안쪽으로 라운드된 곡선이 반대쪽 변의 곡선과 만나거나 통과해 **윤곽이 자기교차**한다.
- 근거: even-odd/non-zero fill에서 자기교차하면 fill 영역이 뒤집혀 글자 속(색칠 칸)이 사라지거나 가는 획이 끊긴다. `RegionPaintEngine.buildLabels`(`RegionPaintEngine.swift:532-604`)는 렌더된 PNG의 어두운 픽셀을 경계로 재라벨링하므로, 경계가 끊기면 칸이 인접 칸/배경과 병합돼 "획 한쪽을 칠하면 글자 전체가 칠해지는" 증상이 난다. v1(0.18은 신규 도입)에는 없던 신규 위험.
- 권고: (1) R 기준을 글리프 bbox가 아니라 **추정 획 폭** 기반으로 낮추거나(예: bbox 짧은변 대신 더 작은 상수 px), (2) 클램프에 "정점에서 인접 변 법선 방향으로 마주보는 변까지 거리" 항을 추가하긴 어려우므로 현실적으로는 `cornerRoundFactor`를 작게(예: 0.08~0.10) + R 상한을 device px 절대값으로 캡. (3) 라운딩 후 `path.boundingBoxOfPath`가 raw 대비 크게 줄지 않는지 디버그 검증. **24자 실제 렌더 PNG 육안/픽셀 검사 필요(확인 필요).**

### M-2. `closeSubpath` 누락 윤곽의 **마지막 변 라운딩 미적용 + 시작/끝점 처리 비일관**
- 위치: `Utilities/HangulGlyphRenderer.swift:58-98`
- 문제: `roundedPolygon`은 **닫힌 다각형** 전제로 `v[(i-1+n)%n]`, `v[(i+1)%n]`로 wrap한다. 정점 배열 `v`는 `start` + 각 `addLine` 끝점으로 만든다(`:80-82`). 라인 `:82`는 시작점과 끝점이 0.5px 이내면 끝점을 제거(`removeLast`)해 닫힌 폐곡선의 중복 정점을 정리한다. 그러나 (a) `closeSubpath` 엘리먼트가 path에 **명시적으로 있을 때**는 마지막 `addLine`이 시작점으로 돌아오지 않을 수 있고(닫힘은 암묵적 직선), 그 암묵적 닫힘 변의 모서리(=시작점)는 `v`에 시작점만 1개 들어가 정상 라운드되지만, (b) `closeSubpath`가 **없고** 단순히 시작점으로 되돌아오는 line만 있는 폰트/엘리먼트 패턴에서 0.5px 임계 밖이면 중복 정점이 남아 0길이 인접 변이 생긴다 — `unit`의 `l<0.0001` 가드(`:107`)로 NaN은 막지만 해당 정점의 라운드 반경이 0이 돼 모서리가 안 둥글어진다(견고성은 OK, 룩만 비일관). 또한 `closeSubpath` 이후 같은 subpath에 추가 엘리먼트가 오는 폰트(드묾)에서는 fresh `Sub()`(start=.zero)에 붙어 `(0,0)` 가짜 정점이 섞일 수 있다.
- 근거: Apple SD Gothic Neo Heavy 글리프는 통상 `closeSubpath`를 명시하므로 실 사용 경로에서 (b)/추가엘리먼트는 드물다. 다만 cascade 폰트가 바뀌면(폰트 미보유 → `CTFontCreateForString` 폴백) 다른 윤곽 패턴이 올 수 있어 견고성 결함으로 남는다.
- 권고: 정점 수집 후 (1) 인접 중복 정점(0길이 변) 제거를 일반화(0.5px가 아니라 모든 인접쌍 dedup), (2) `closeSubpath` 이후 추가 엘리먼트가 오면 새 `Sub`로 분리하도록 가드 추가, (3) 직선-only 판정 시 `s.closed`도 요구해(열린 직선 윤곽은 폐곡선 라운딩 대상에서 제외) 안전화.

---

## MINOR

### m-1. R = 0(또는 음수 bbox)·정점<3 경로의 결과 비일관 — 견고성은 OK, 룩만
- 위치: `Utilities/HangulGlyphRenderer.swift:74,79,103`
- 사실: `lineOnly && s.segs.count >= 3`(`:79`)로 직선 3개 미만은 라운딩을 건너뛰지 않고 **원본 복제 분기**(`:84`)로 떨어져 그대로 그려진다 → 깨지지 않음. `roundedPolygon`의 `guard n>=3`(`:103`)도 이중 안전. R이 0이면(예: bbox 한 변이 0) `t1=t2=정점`이라 quadCurve가 점으로 수축, 결과는 원본 다각형과 동일(견고). NaN/0나눗셈은 `unit`의 `l<0.0001` 가드로 차단.
- 권고: 조치 불필요. 견고성 충족.

### m-2. 직선-only 판정은 곡선 윤곽(ㅅ·ㅎ·ㅇ)을 **안전 통과** — 확인됨
- 위치: `Utilities/HangulGlyphRenderer.swift:78,84-95`, quad 점 순서 `:65,90`
- 사실: `allSatisfy { if case .line }`로 quad/curve가 하나라도 있으면 원본 복제. ㅇ(완전 곡선)·ㅎ(꼭지 곡선)·ㅅ(직선이지만 곡선 분기 없으면 라운드 대상) 보존. `addQuadCurveToPoint`의 `points[0]=control`,`points[1]=end`를 `.quad(control,end)`로 저장 후 `addQuadCurve(to:end,control:control)`로 재생 — **CoreText 점 순서와 일치**(정확). ㅅ은 통상 폐다각형이라 라운딩되며, 이는 의도된 룩.
- 근거: 곡선 복제 분기는 path를 변형하지 않으므로 채색 호환 안전.
- 권고: 조치 불필요.

### m-3. regen 시 `album.templates` 순회 중 `context.delete` — 스냅샷 권장(현재는 filter가 새 배열 생성으로 우연히 안전)
- 위치: `Utilities/HangulSeeder.swift:76`
- 사실: `for t in album.templates.filter({ $0.isSystem }) { context.delete(t) }`. `filter`가 **새 Array를 만들어** 그걸 순회하므로 원본 관계 컬렉션 변형 중 순회로 인한 크래시는 발생하지 않는다(우연히 안전). 다만 의존이 암묵적이라 `filter` 제거/리팩터 시 깨질 수 있다.
- 권고: `let toDelete = album.templates.filter { $0.isSystem }; toDelete.forEach(context.delete)`로 스냅샷 의도를 명시(선택).

---

## NIT

### n-1. 메인 블로킹/0회 단축 — **이상 없음** 확인
- `ensure`(@MainActor)는 가벼운 fetch(스칼라 isSystem/name)만 메인에서 하고(`HangulSeeder.swift:39-49`), 라운딩 포함 무거운 렌더는 `Task.detached(priority:.utility)`의 `renderPayload`에서만 돈다(`:62-64,105-115`). `roundedCorners`/`roundedPolygon`/`draw`는 모두 `nonisolated`라 detached에서 호출돼 메인을 막지 않는다. 통상(버전 일치·24자·커버 존재) 시 `:53` guard에서 즉시 반환 → 렌더 0회. v2 변경이 0회 단축 규약을 깨지 않음(체크포인트 1 충족).

### n-2. M-1(중복 시드)·M-2(부분실패 자가복구) 회귀 — **유지** 확인
- `isSeeding` 가드(`HangulSeeder.swift:36,55,61 defer`), 삽입 직전 메인 보유글자 재확인(`:81-82`), 24자 충족 시에만 버전 확정(`:89-91`) 모두 v2에서 유지. regen 경로도 같은 `isSeeding`/`Task` 안에서 delete→insert→save가 한 MainActor 실행으로 묶여 **원자적**(중간 await는 detached 렌더 1회뿐, 그 사이 재진입은 isSeeding이 차단). 부분 완료 시 버전 미확정 → 다음 `ensure`가 `storedVersion(0 또는 1) != 2`로 needsRegen 재진입해 재시도 → 자가복구. 앱 종료 후 재시작도 동일 복구(체크포인트 3·5 충족).
- 단, regen 도중 store는 save됐는데 UserDefaults 버전 set 직전 종료되면 다음 실행이 또 needsRegen → **이미 v2로 렌더된 24자를 한 번 더 삭제·재렌더**한다(결과는 동일, 1회 헛수고). store에 24자 전부 있으면 굳이 재생성 않도록 "버전 미확정이어도 24자 system Template이 이미 있으면 버전만 확정" 단축을 추가하면 헛수고 제거 가능(선택, m급 미만).

---

## "이상 없음" 명시 판정 (중점 검수 포인트 대조)
- **1 렌더비용/메인블로킹**: 라운딩+렌더 detached 한정, 통상 0회. 충족(n-1).
- **2 라운딩 정확성/견고성**: NaN/0가드·정점<3·곡선통과·quad순서 정확(m-1,m-2). 단 **자기교차(M-1)·닫힘처리(M-2)** 결함.
- **3 regen 레이스/자가복구**: isSeeding 원자성·버전 24자 조건·자가복구 충족(n-2). 순회 중 delete는 우연히 안전(m-3). UserDefaults↔store desync는 헛수고만 유발(무손상).
- **4 채색 호환**: 닫힌 윤곽·검은 stroke 경계 유지가 정상 케이스. **단 M-1 자기교차 시 칸 병합 위험** — 실 PNG 검증 필요(확인 필요).
- **5 회귀(M-1/M-2 v7)**: 유지 확인(n-2).

---

## 요약

| 심각도 | 건수 | 항목 |
|---|---|---|
| blocker | 0 | — |
| major | 2 | M-1 라운딩 자기교차→채색 영역 손실, M-2 closeSubpath/시작끝점 처리 비일관 |
| minor | 3 | m-1 R=0/정점<3(견고 OK), m-2 곡선 통과·quad순서(정확), m-3 순회중 delete 스냅샷 |
| nit | 2 | n-1 메인블로킹 없음, n-2 M-1/M-2 가드 유지 |

**Top 3 우선 수정**: M-1(`cornerRoundFactor` 축소 + R을 획폭 기준/절대 px 캡 → 자기교차 차단, 24자 PNG 픽셀 검증) → M-2(인접 정점 dedup 일반화 + `s.closed` 요구로 열린 윤곽 라운딩 제외) → n-2 보강(store 24자 존재 시 버전만 확정해 종료-재시작 헛 재생성 제거, 선택).
