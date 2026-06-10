import Foundation
import SwiftData

/// 앨범 — 도안을 묶는 폴더형 카테고리 (전역 공유).
/// 사용자 노출 표기 "앨범" = 기획 §화면 1.5. (모델명은 ObjC 런타임의 `Category` 타입과
/// 충돌해 `Album` 으로 명명 — 의미는 동일.)
///
/// - 도안은 **하나의 앨범에만** 속한다(`Template.album`, 단일 소속).
/// - 앨범 미지정 도안(`album == nil`)은 **미분류** 가상 묶음으로 묶인다.
/// - 앨범 삭제 시 `deleteRule: .nullify` → 안의 도안은 사라지지 않고 **미분류로 이동**.
@Model
final class Album {
    var name: String
    /// 대표 이미지(다운샘플 보관). 캐러셀 카드 커버. nil 이면 플레이스홀더.
    @Attribute(.externalStorage) var coverImageData: Data?
    var createdAt: Date

    /// 시스템(앱 기본 제공) 앨범 여부. true = '한글'·'알파벳' 같은 보호 앨범 → 삭제·이름변경·대표이미지
    /// 변경 불가, 캐러셀 앞쪽 고정, 안의 도안도 보호. (기획 §기본 제공 한글/알파벳 앨범, 2026-06-09)
    /// 경량 마이그레이션: 기존 행은 기본값 false.
    var isSystem: Bool = false

    /// 시스템 앨범 종류 식별자. `"hangul"` / `"alphabet"` / `nil`(일반 앨범).
    /// 시스템 앨범이 둘 이상이 되어 **이름 문자열이 아니라 이 키로** 캐러셀 순서·ensure-exists를
    /// 판정한다(이름 변경·현지화에 견고). (디자인 §33-3, 2026-06-09)
    /// 경량 마이그레이션: 기존 행은 nil → 시더가 이름으로 1회 백필.
    var systemKind: String? = nil

    /// 이 앨범에 속한 도안들. 앨범 삭제 시 nullify → 도안의 album 이 nil(미분류)이 된다.
    @Relationship(deleteRule: .nullify, inverse: \Template.album)
    var templates: [Template] = []

    init(name: String, coverImageData: Data? = nil, createdAt: Date = .now,
         isSystem: Bool = false, systemKind: String? = nil) {
        self.name = name
        self.coverImageData = coverImageData
        self.createdAt = createdAt
        self.isSystem = isSystem
        self.systemKind = systemKind
    }
}
