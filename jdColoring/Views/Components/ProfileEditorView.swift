import SwiftUI
import PhotosUI

/// 프로필 추가/수정 폼 카드. 추가와 수정 모두에서 재사용.
struct ProfileEditorView: View {
    let title: String
    let colorIndex: Int
    @Binding var name: String
    @Binding var imageData: Data?
    var onCancel: () -> Void
    var onSave: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var isProcessing = false
    @State private var loadTask: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 24) {
            Text(title)
                .font(Theme.rounded(30, weight: .heavy))
                .foregroundStyle(Theme.ink)

            PhotosPicker(selection: $pickerItem, matching: .images) {
                imagePickerLabel
            }
            .buttonStyle(.plain)

            TextField("이름을 입력하세요", text: $name)
                .font(Theme.rounded(22))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 360)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(hex: 0xFAF3EC)))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.cardBorder, lineWidth: 2))
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { if canSave { onSave() } }

            HStack(spacing: 20) {
                Button(action: onCancel) {
                    Text("취소")
                        .font(Theme.rounded(22, weight: .bold))
                        .foregroundStyle(Theme.coral)
                        .frame(width: 150, height: 56)
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.coral, lineWidth: 2.5))
                }
                .buttonStyle(.plain)

                Button(action: onSave) {
                    Text("저장")
                        .font(Theme.rounded(22, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 150, height: 56)
                        .background(RoundedRectangle(cornerRadius: 18)
                            .fill(canSave ? Theme.coral : Theme.coral.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
        }
        .padding(40)
        .frame(width: 500)
        .background(RoundedRectangle(cornerRadius: 36).fill(Theme.card))
        .shadow(color: Theme.softShadow, radius: 24, x: 0, y: 10)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            loadTask?.cancel()   // 연속 선택 시 이전 다운샘플 작업 취소
            isProcessing = true
            loadTask = Task {
                let thumb = await loadThumbnail(from: item)
                if Task.isCancelled { return }
                await MainActor.run {
                    if let thumb { imageData = thumb }
                    isProcessing = false
                }
            }
        }
        .onDisappear { loadTask?.cancel() }
        .onAppear { nameFocused = true }
    }

    // MARK: - 이미지 픽커 라벨

    private var imagePickerLabel: some View {
        ZStack {
            Circle().fill(Color(hex: 0xFAF3EC)).frame(width: 156, height: 156)

            if let imageData, let image = Image(data: imageData) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 156, height: 156)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Theme.ring(colorIndex), lineWidth: 8))
            } else {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [8, 8]))
                    .foregroundStyle(Color(hex: 0xD8C9BA))
                    .frame(width: 156, height: 156)
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.coral)
                    Text("갤러리에서\n사진 선택")
                        .multilineTextAlignment(.center)
                        .font(Theme.rounded(15, weight: .semibold))
                        .foregroundStyle(Theme.coral)
                }
            }

            if isProcessing {
                ProgressView()
            }
        }
    }

    // MARK: - 다운샘플링 (백그라운드)

    private func loadThumbnail(from item: PhotosPickerItem) async -> Data? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            ImageDownsampler.thumbnailData(from: data, maxPixel: 512)
        }.value
    }
}
