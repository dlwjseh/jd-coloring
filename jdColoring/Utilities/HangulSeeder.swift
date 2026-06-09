import Foundation
import SwiftData

/// 앱 기본 제공 '한글' 앨범 + 자음14·모음10 도안을 **있는지 확인 후 없으면 생성**(ensure-exists)한다.
/// (기획/디자인 §기본 제공 한글 앨범, 2026-06-09)
///
/// - **seed-once 아님**: 시작할 때마다 24자가 다 있는지 `name` 키로 확인 → 없는 글자만 생성.
///   보호 앨범이라 지워질 일은 없지만 데이터 손상/마이그레이션 시 자동 복구된다. 다 있으면 **렌더 0회.**
/// - 글리프 렌더(무거움)는 **백그라운드**에서 PNG Data까지만 만들고, SwiftData 삽입만 메인에서 한다.
///   (모델/ModelContext 는 Sendable 이 아니므로 detached 로 넘기지 않는다 — Data 만 actor 경계를 넘긴다.)
@MainActor
enum HangulSeeder {

    /// 자모 순(자음 먼저, 모음 나중) — 갤러리 그리드·생성 순서.
    static let consonants = ["ㄱ", "ㄴ", "ㄷ", "ㄹ", "ㅁ", "ㅂ", "ㅅ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]
    static let vowels = ["ㅏ", "ㅑ", "ㅓ", "ㅕ", "ㅗ", "ㅛ", "ㅜ", "ㅠ", "ㅡ", "ㅣ"]
    static var allJamo: [String] { consonants + vowels }

    // 백그라운드 렌더(nonisolated)에서도 읽으므로 nonisolated 상수로 둔다.
    nonisolated private static let fullSide: CGFloat = 1024   // 색칠용
    nonisolated private static let thumbSide: CGFloat = 480   // 그리드 썸네일
    nonisolated private static let coverSide: CGFloat = 640

    /// 글리프 렌더 버전. 글자 룩(두께·모서리 등)을 바꾸면 +1 → 기존 시드 도안을 **재생성**한다.
    /// v1 = 최초(NSAttributedString 얇은 외곽선). v2 = Heavy 웨이트 + 둥근 모서리 + 넓은 색칠영역(2026-06-09).
    private static let glyphVersion = 2
    private static let versionKey = "hangulGlyphRenderVersion"

    /// 진행 중 가드(M-1): 비동기 렌더 gap 동안 `ensure` 재진입으로 24자가 중복 삽입되는 것을 막는다.
    /// (시작 + 캐러셀 진입 양쪽에서 호출되므로 멱등성 필수.)
    private static var isSeeding = false

    /// 시작 경로(`RootView.onAppear`) + 안전 재시도(`AlbumCarouselView.onAppear`)에서 호출.
    /// 부족분이 없으면 즉시 반환(렌더·삽입 0회). 부분 완료/실패는 다음 호출이 missing 재계산으로 자가복구.
    static func ensure(context: ModelContext) {
        guard !isSeeding else { return }   // M-1: 진행 중이면 재진입 차단

        // 1) 메인에서 가벼운 존재 확인 — 시스템 앨범 + 보유 글자 집합(스칼라 name/isSystem만, blob 미디코딩).
        let systemAlbums = (try? context.fetch(FetchDescriptor<Album>(predicate: #Predicate { $0.isSystem }))) ?? []
        let existing = systemAlbums.first

        // 글리프 룩이 바뀌었으면(버전 불일치) 기존 시드 도안을 전부 재생성.
        let storedVersion = UserDefaults.standard.integer(forKey: versionKey)
        let needsRegen = (existing != nil) && (storedVersion != glyphVersion)

        let haveNames: Set<String> = needsRegen
            ? []   // 재생성 → 전부 missing 취급
            : (existing.map { Set($0.templates.filter { $0.isSystem }.map(\.name)) } ?? [])
        let missing = allJamo.filter { !haveNames.contains($0) }
        let needCover = needsRegen || (existing?.coverImageData == nil)

        // 앨범도 있고 24자도 다 있고 커버도 있고 버전도 같으면 → 할 일 없음.
        guard existing == nil || !missing.isEmpty || needCover else { return }

        isSeeding = true
        let albumID = existing?.persistentModelID
        let regen = needsRegen

        // 2) 백그라운드 렌더(Data 만 반환) → 3) 메인에서 삽입.
        Task {   // @MainActor 상속(ensure 가 MainActor) — 삽입/저장은 메인에서.
            defer { isSeeding = false }   // 완료/실패 무관 가드 해제 → 다음 호출이 재시도(M-2 자가복구)
            let payload = await Task.detached(priority: .utility) {
                renderPayload(missing: missing, needCover: needCover)
            }.value

            let album: Album
            if let albumID, let found = context.model(for: albumID) as? Album {
                album = found
            } else {
                album = Album(name: "한글", isSystem: true)
                context.insert(album)
            }
            if regen {
                // 글리프 룩 변경 → 기존 시스템 도안 교체. 연결된 Artwork 는 cascade 삭제
                // (한글 글자에 칠하던 색칠은 초기화됨 — 룩 변경에 따른 불가피한 영향).
                // m-3: 순회 중 삭제가 관계 배열을 변형하지 않도록 스냅샷을 떠서 삭제.
                let toDelete = album.templates.filter { $0.isSystem }
                for t in toDelete { context.delete(t) }
                album.coverImageData = nil
            }
            if album.coverImageData == nil, let cover = payload.cover { album.coverImageData = cover }
            // M-1: 렌더 사이 다른 경로가 채웠을 수 있으니 삽입 직전 메인에서 보유 글자 재확인 → 중복 방지.
            let nowHave = Set(album.templates.filter { $0.isSystem }.map(\.name))
            for g in payload.glyphs where !nowHave.contains(g.name) {
                context.insert(Template(name: g.name, imageData: g.full, thumbnailData: g.thumb,
                                        album: album, isSystem: true))
            }
            try? context.save()

            // 24자가 모두 갖춰졌을 때만 렌더 버전을 확정(부분 실패 시 다음 호출이 재시도).
            if album.templates.filter({ $0.isSystem }).count >= allJamo.count {
                UserDefaults.standard.set(glyphVersion, forKey: versionKey)
            }
        }
    }

    // MARK: - 백그라운드 렌더

    /// actor 경계를 넘는 순수 Data 묶음(Sendable).
    private struct Payload: Sendable {
        struct Glyph: Sendable { let name: String; let full: Data; let thumb: Data }
        let glyphs: [Glyph]
        let cover: Data?
    }

    /// 백그라운드에서 호출 — 모델/컨텍스트를 만지지 않고 PNG Data 만 생성한다.
    nonisolated private static func renderPayload(missing: [String], needCover: Bool) -> Payload {
        var glyphs: [Payload.Glyph] = []
        glyphs.reserveCapacity(missing.count)
        for j in missing {
            guard let full = HangulGlyphRenderer.outlineImage(j, side: fullSide),
                  let thumb = HangulGlyphRenderer.outlineImage(j, side: thumbSide) else { continue }
            glyphs.append(.init(name: j, full: full, thumb: thumb))
        }
        let cover = needCover ? HangulGlyphRenderer.coverImage(side: coverSide) : nil
        return Payload(glyphs: glyphs, cover: cover)
    }
}
