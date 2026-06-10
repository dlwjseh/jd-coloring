import Foundation
import SwiftData

/// 도안 수동 정렬(`Template.sortOrder`)의 **최초 1회 백필**.
/// (기획/디자인 §도안 정렬, 2026-06-09)
///
/// `sortOrder` 신설 전의 기존 도안은 전부 기본값 0 → 그대로 두면 동률이라 정렬이 createdAt 폴백에만
/// 의존한다. 앱 첫 기동 시 **앨범(또는 미분류) 그룹별로 createdAt 순서대로 0,1,2…** 를 부여해 현재
/// 보이는 순서를 그대로 굳힌다. 이후 사용자가 '정렬' 모드에서 끌어 바꾸면 그 값을 덮어쓴다.
///
/// - **앱 실행마다 재실행 금지**: `UserDefaults` 플래그로 1회만(평가자 체크포인트).
/// - 시스템 앨범('한글'·'알파벳') 글자 도안은 시더가 글자 인덱스로 sortOrder 를 직접 부여하지만,
///   이미 시드된 레거시 행이 0으로 남아 있을 수 있어 여기서도 함께 묶여 createdAt(=삽입=글자) 순으로
///   정돈된다(자모/알파벳 순 유지).
enum SortOrderBackfill {
    private static let doneKey = "templateSortOrderBackfilled.v1"

    @MainActor
    static func runOnce(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

        let all = (try? context.fetch(FetchDescriptor<Template>())) ?? []
        guard !all.isEmpty else {
            // 도안이 아직 없으면(첫 실행 직후) 백필할 게 없다 → 플래그를 세우지 않고 다음 기동에 재시도.
            // (시더가 글자 도안을 넣은 뒤 정돈되도록.)
            return
        }

        // 앨범 id(미분류 = nil)별로 묶어 그룹 내 createdAt 오름차순으로 0..n 부여.
        var groups: [PersistentIdentifier?: [Template]] = [:]
        for t in all { groups[t.album?.persistentModelID, default: []].append(t) }
        for (_, group) in groups {
            let ordered = group.sorted { $0.createdAt < $1.createdAt }
            for (i, t) in ordered.enumerated() where t.sortOrder != i { t.sortOrder = i }
        }

        do {
            try context.save()
            UserDefaults.standard.set(true, forKey: doneKey)
        } catch {
            print("sortOrder 백필 실패(다음 기동 재시도): \(error)")
        }
    }
}
