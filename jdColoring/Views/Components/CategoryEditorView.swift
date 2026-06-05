import SwiftUI
import PhotosUI

/// 앨범 만들기/수정 시트 (디자인 §29). 대표 그림(선택) + 이름(필수).
/// 추가·수정 모두에서 재사용.
struct CategoryEditorView: View {
    let title: String
    let confirmTitle: String          // "만들기" 또는 "저장"
    @Binding var name: String
    @Binding var coverData: Data?
    var onCancel: () -> Void
    var onSave: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var isProcessing = false
    @State private var loadTask: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing
    }

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 6) {
                Text(title)
                    .font(Theme.rounded(32, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("이름을 정하고 대표 그림을 골라요")
                    .font(Theme.rounded(18))
                    .foregroundStyle(Theme.subText)
            }

            PhotosPicker(selection: $pickerItem, matching: .images) {
                coverPickerLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel("대표 그림 선택")

            TextField("앨범 이름 (필수)", text: $name)
                .font(Theme.rounded(20))
                .textFieldStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 460)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.cardBorder, lineWidth: 1.5))
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { if canSave { onSave() } }

            HStack(spacing: 20) {
                Button(action: onCancel) {
                    Text("취소")
                        .font(Theme.rounded(21, weight: .bold))
                        .foregroundStyle(Theme.coral)
                        .frame(width: 180, height: 58)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.coral, lineWidth: 2.5))
                }
                .buttonStyle(.plain)

                Button(action: onSave) {
                    Text(confirmTitle)
                        .font(Theme.rounded(21, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 180, height: 58)
                        .background(RoundedRectangle(cornerRadius: 16)
                            .fill(canSave ? Theme.coral : Theme.coral.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .accessibilityHint(canSave ? "" : "앨범 이름을 입력하세요")
            }
        }
        .padding(40)
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 40).fill(Theme.card))
        .shadow(color: Theme.softShadow, radius: 24, x: 0, y: 10)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            loadTask?.cancel()
            isProcessing = true
            loadTask = Task {
                let cover = await loadCover(from: item)
                if Task.isCancelled { return }
                await MainActor.run {
                    if let cover { coverData = cover }
                    isProcessing = false
                }
            }
        }
        .onDisappear { loadTask?.cancel() }
        .onAppear { nameFocused = true }
    }

    // MARK: - 대표 그림 픽커 라벨 (230×230 라운드 스퀘어)

    private var coverPickerLabel: some View {
        ZStack {
            if let coverData, let image = ThumbnailCache.image(for: coverData) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 230, height: 230)
                    .clipShape(RoundedRectangle(cornerRadius: 32))
                    .overlay(RoundedRectangle(cornerRadius: 32).stroke(Theme.cardBorder, lineWidth: 2))
            } else {
                RoundedRectangle(cornerRadius: 32).fill(Color(hex: 0xFFF6F2))
                    .frame(width: 230, height: 230)
                RoundedRectangle(cornerRadius: 32)
                    .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [10, 9]))
                    .foregroundStyle(Theme.coral)
                    .frame(width: 230, height: 230)
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.coral)
                    Text("대표 그림 선택")
                        .font(Theme.rounded(18, weight: .bold))
                        .foregroundStyle(Theme.coral)
                    Text("(선택 · 사진에서)")
                        .font(Theme.rounded(14))
                        .foregroundStyle(Theme.faintText)
                }
            }
            if isProcessing { ProgressView() }
        }
        .frame(width: 230, height: 230)
    }

    // MARK: - 다운샘플 (백그라운드)

    private func loadCover(from item: PhotosPickerItem) async -> Data? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            ImageDownsampler.thumbnailData(from: data, maxPixel: 600)
        }.value
    }
}
