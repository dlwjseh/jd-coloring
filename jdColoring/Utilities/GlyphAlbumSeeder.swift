import Foundation
import SwiftData
import UIKit

/// 앱 기본 제공 글리프 앨범('한글' 자음·모음, '알파벳' 대·소문자)을 **있는지 확인 후 없으면 생성**(ensure-exists).
/// (기획/디자인 §기본 제공 한글/알파벳 앨범, 2026-06-09)
///
/// 원래 한글 전용 `HangulSeeder` 를 **종류(`Kind`)로 일반화**한 것. 시스템 앨범이 둘 이상이 되어:
///  - 앨범 식별을 `isSystem` Bool 이 아니라 **`Album.systemKind`**("hangul"/"alphabet")로 한다(이름 비의존).
///  - **진행 가드(M-1)를 종류별**로 둔다(`seeding` Set) — 한쪽 시드가 다른 쪽을 막지 않게.
///  - 기존 `systemKind == nil` 한글 앨범은 이름으로 1회 **백필**(마이그레이션 보정).
///
/// 동작 원칙(한글 시절 그대로):
///  - **seed-once 아님**: 시작 때마다 글자 키가 다 있는지 확인 → 없는 글자만 생성. 다 있으면 **렌더 0회.**
///  - 글리프 렌더(무거움)는 **백그라운드**에서 PNG Data 까지만, SwiftData 삽입만 메인.
///    (actor 경계는 Sendable 한 systemKind/[글자]/Bool 만 넘긴다 — 모델/컨텍스트/UIColor 안 넘김.)
@MainActor
enum GlyphAlbumSeeder {

    // MARK: - 종류 정의

    struct Kind {
        let systemKind: String          // "hangul" / "alphabet" — Album.systemKind 키
        let albumName: String           // 표시 이름 + 백필 매칭
        let glyphs: [String]            // 생성/존재판정 글자 (표시·생성 순)
        let glyphVersion: Int           // 룩 변경 시 +1 → 기존 시드 재생성
        let versionKey: String          // UserDefaults 버전 저장 키
    }

    /// 자음 먼저·모음 나중(자모 순). 한글 글리프 v2 = Heavy + 둥근 모서리(2026-06-09).
    static let hangul = Kind(
        systemKind: "hangul",
        albumName: "한글",
        glyphs: ["ㄱ","ㄴ","ㄷ","ㄹ","ㅁ","ㅂ","ㅅ","ㅇ","ㅈ","ㅊ","ㅋ","ㅌ","ㅍ","ㅎ",
                 "ㅏ","ㅑ","ㅓ","ㅕ","ㅗ","ㅛ","ㅜ","ㅠ","ㅡ","ㅣ"],
        glyphVersion: 2,
        versionKey: "hangulGlyphRenderVersion"
    )

    /// 대문자 A–Z(26) → 소문자 a–z(26) 순(디자인 §33-0-2). 알파벳 글리프 v1(신규).
    static let alphabet = Kind(
        systemKind: "alphabet",
        albumName: "알파벳",
        glyphs: (UnicodeScalar("A").value...UnicodeScalar("Z").value).map { String(UnicodeScalar($0)!) }
              + (UnicodeScalar("a").value...UnicodeScalar("z").value).map { String(UnicodeScalar($0)!) },
        glyphVersion: 1,
        versionKey: "alphabetGlyphRenderVersion"
    )

    static let allKinds: [Kind] = [hangul, alphabet]

    /// 진행 중 가드(M-1) — **종류별**. 한쪽 시드 중 다른 쪽이 막히지 않게 systemKind 단위로 관리.
    private static var seeding: Set<String> = []

    // 백그라운드 렌더(nonisolated)에서도 읽으므로 nonisolated 상수.
    nonisolated private static let fullSide: CGFloat = 1024   // 색칠용
    nonisolated private static let thumbSide: CGFloat = 480   // 그리드 썸네일
    nonisolated private static let coverSide: CGFloat = 640

    // MARK: - ensure

    /// 시작 경로(`RootView.onAppear`) + 안전 재시도(`AlbumCarouselView.onAppear`)에서 호출.
    static func ensureAll(context: ModelContext) {
        for kind in allKinds { ensure(kind, context: context) }
    }

    /// 한 종류의 시스템 앨범 + 글자 도안을 보장한다. 부족분 없으면 즉시 반환(렌더·삽입 0회).
    static func ensure(_ kind: Kind, context: ModelContext) {
        guard !seeding.contains(kind.systemKind) else { return }   // M-1: 종류별 진행 중이면 차단

        // 1) 시스템 앨범 조회(스칼라만). systemKind 우선, 없으면 이름으로 백필(레거시 보정).
        let systemAlbums = (try? context.fetch(FetchDescriptor<Album>(predicate: #Predicate { $0.isSystem }))) ?? []
        var existing = systemAlbums.first { $0.systemKind == kind.systemKind }
        if existing == nil, let legacy = systemAlbums.first(where: { $0.systemKind == nil && $0.name == kind.albumName }) {
            legacy.systemKind = kind.systemKind     // 백필: pre-systemKind 행에 키 부여
            try? context.save()
            existing = legacy
        }

        // 글리프 룩이 바뀌었으면(버전 불일치) 기존 시드 도안을 전부 재생성.
        let storedVersion = UserDefaults.standard.integer(forKey: kind.versionKey)
        let needsRegen = (existing != nil) && (storedVersion != kind.glyphVersion)

        let haveNames: Set<String> = needsRegen
            ? []
            : (existing.map { Set($0.templates.filter { $0.isSystem }.map(\.name)) } ?? [])
        let missing = kind.glyphs.filter { !haveNames.contains($0) }
        let needCover = needsRegen || (existing?.coverImageData == nil)

        // 앨범도 있고 글자도 다 있고 커버도 있고 버전도 같으면 → 할 일 없음.
        guard existing == nil || !missing.isEmpty || needCover else { return }

        seeding.insert(kind.systemKind)
        let albumID = existing?.persistentModelID
        let regen = needsRegen
        let sysKind = kind.systemKind
        let albumName = kind.albumName
        let glyphOrder = kind.glyphs           // 글자 정렬 인덱스(자모/알파벳 순) → Template.sortOrder
        let allCount = kind.glyphs.count
        let versionKey = kind.versionKey
        let version = kind.glyphVersion

        // 2) 백그라운드 렌더(Data 만 반환) → 3) 메인에서 삽입.
        Task {
            defer { seeding.remove(sysKind) }   // 완료/실패 무관 가드 해제 → 다음 호출이 재시도(M-2 자가복구)
            let payload = await Task.detached(priority: .utility) {
                renderPayload(systemKind: sysKind, missing: missing, needCover: needCover)
            }.value

            let album: Album
            if let albumID, let found = context.model(for: albumID) as? Album {
                album = found
            } else {
                album = Album(name: albumName, isSystem: true, systemKind: sysKind)
                context.insert(album)
            }
            if regen {
                // 글리프 룩 변경 → 기존 시스템 도안 교체. 연결 Artwork 는 cascade 삭제(룩 변경에 따른 불가피한 초기화).
                // m-3: 순회 중 삭제가 관계 배열을 변형하지 않도록 스냅샷을 떠서 삭제.
                let toDelete = album.templates.filter { $0.isSystem }
                for t in toDelete { context.delete(t) }
                album.coverImageData = nil
            }
            if album.coverImageData == nil, let cover = payload.cover { album.coverImageData = cover }
            // M-1: 렌더 사이 다른 경로가 채웠을 수 있으니 삽입 직전 메인에서 보유 글자 재확인 → 중복 방지.
            let nowHave = Set(album.templates.filter { $0.isSystem }.map(\.name))
            for g in payload.glyphs where !nowHave.contains(g.name) {
                // sortOrder = 글자의 자모/알파벳 인덱스 → 시스템 앨범은 항상 고정 순서로 표시(잠금).
                let order = glyphOrder.firstIndex(of: g.name) ?? album.templates.count
                context.insert(Template(name: g.name, imageData: g.full, thumbnailData: g.thumb,
                                        album: album, isSystem: true, sortOrder: order))
            }
            try? context.save()

            // 글자가 모두 갖춰졌을 때만 렌더 버전을 확정(부분 실패 시 다음 호출이 재시도).
            if album.templates.filter({ $0.isSystem }).count >= allCount {
                UserDefaults.standard.set(version, forKey: versionKey)
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

    /// 백그라운드에서 호출 — 모델/컨텍스트를 만지지 않고 PNG Data 만 생성한다. systemKind 로 폰트·커버 결정.
    nonisolated private static func renderPayload(systemKind: String, missing: [String], needCover: Bool) -> Payload {
        let font = glyphFont(for: systemKind)
        var glyphs: [Payload.Glyph] = []
        glyphs.reserveCapacity(missing.count)
        for g in missing {
            guard let full = GlyphOutlineRenderer.outlineImage(g, side: fullSide, font: font),
                  let thumb = GlyphOutlineRenderer.outlineImage(g, side: thumbSide, font: font) else { continue }
            glyphs.append(.init(name: g, full: full, thumb: thumb))
        }
        let cover = needCover ? renderCover(systemKind: systemKind) : nil
        return Payload(glyphs: glyphs, cover: cover)
    }

    nonisolated private static func glyphFont(for systemKind: String) -> GlyphOutlineRenderer.GlyphFont {
        systemKind == "hangul" ? .korean : .latinRounded
    }

    /// 커버 자동 생성 — 한글: 소프트블루(#E9EEFF) + ㄱㄴㅏㅑ / 알파벳: 소프트민트(#E6F5EC) + A B a b (디자인 §33-1).
    nonisolated private static func renderCover(systemKind: String) -> Data? {
        let pink = UIColor(red: 1, green: 0xD7/255, blue: 0xE9/255, alpha: 1)
        let yellow = UIColor(red: 1, green: 0xE9/255, blue: 0xA8/255, alpha: 1)
        let mint = UIColor(red: 0xCD/255, green: 0xEB/255, blue: 0xD6/255, alpha: 1)
        switch systemKind {
        case "hangul":
            let bg = UIColor(red: 0xE9/255, green: 0xEE/255, blue: 0xFF/255, alpha: 1)
            let layout: [(String, UIColor, Int, Int)] = [
                ("ㄱ", .white, 0, 0), ("ㄴ", pink, 1, 0),
                ("ㅏ", yellow, 0, 1), ("ㅑ", .white, 1, 1),
            ]
            return GlyphOutlineRenderer.coverImage(side: coverSide, background: bg, layout: layout, font: .korean)
        default:    // alphabet
            let bg = UIColor(red: 0xE6/255, green: 0xF5/255, blue: 0xEC/255, alpha: 1)
            let layout: [(String, UIColor, Int, Int)] = [
                ("A", .white, 0, 0), ("B", pink, 1, 0),
                ("a", yellow, 0, 1), ("b", mint, 1, 1),
            ]
            return GlyphOutlineRenderer.coverImage(side: coverSide, background: bg, layout: layout, font: .latinRounded)
        }
    }
}
