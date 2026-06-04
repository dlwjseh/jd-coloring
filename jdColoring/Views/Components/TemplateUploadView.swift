import SwiftUI
import PhotosUI

/// 도안 만들기 시트 — 사진 선택 → 미리보기 → 저장. (사진을 가공 없이 그대로 도안으로 등록)
struct TemplateUploadView: View {
    var onCancel: () -> Void
    /// (도안 이름, 색칠용 이미지, 그리드 표시용 썸네일)
    var onSave: (String, Data, Data) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var imageData: Data?       // 색칠용(다운샘플) + 미리보기
    @State private var thumbnailData: Data?    // 그리드 표시용
    @State private var templateName = ""
    @State private var isProcessing = false
    @State private var loadTask: Task<Void, Never>?

    private var hasImage: Bool { imageData != nil }
    private var canSave: Bool { imageData != nil && thumbnailData != nil && !isProcessing }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("도안 만들기")
                    .font(Theme.rounded(30, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("사진을 골라 색칠 도안으로 추가해요")
                    .font(Theme.rounded(18))
                    .foregroundStyle(Theme.subText)
            }

            if hasImage {
                preview

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Text("사진 다시 선택")
                        .font(Theme.rounded(17, weight: .semibold))
                        .foregroundStyle(Theme.coral)
                }
                .buttonStyle(.plain)
            } else {
                emptyPicker
            }

            // 도안 이름 입력 — 선택 사항. 비워도 저장 가능.
            TextField("도안 이름 (선택)", text: $templateName)
                .font(Theme.rounded(18))
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.cardBorder, lineWidth: 1.5))
                .submitLabel(.done)

            HStack(spacing: 20) {
                Button(action: onCancel) {
                    Text("취소")
                        .font(Theme.rounded(22, weight: .bold))
                        .foregroundStyle(Theme.coral)
                        .frame(width: 160, height: 58)
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.coral, lineWidth: 2.5))
                }
                .buttonStyle(.plain)

                Button {
                    if let img = imageData, let thumb = thumbnailData {
                        onSave(templateName.trimmingCharacters(in: .whitespaces), img, thumb)
                    }
                } label: {
                    Text("도안 저장")
                        .font(Theme.rounded(22, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 160, height: 58)
                        .background(RoundedRectangle(cornerRadius: 20)
                            .fill(canSave ? Theme.coral : Theme.coral.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
            }
        }
        .padding(40)
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 40).fill(Theme.card))
        .shadow(color: Theme.softShadow, radius: 24, x: 0, y: 10)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            startProcessing(item)
        }
        .onDisappear {
            loadTask?.cancel()
            templateName = ""
        }
    }

    // MARK: - Subviews

    private var emptyPicker: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            VStack(spacing: 14) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.coral)
                Text("갤러리에서 사진 선택")
                    .font(Theme.rounded(20, weight: .semibold))
                    .foregroundStyle(Theme.coral)
            }
            .frame(width: 300, height: 300)
            .background(RoundedRectangle(cornerRadius: 28).fill(Color(hex: 0xFAF3EC)))
            .overlay(RoundedRectangle(cornerRadius: 28)
                .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                .foregroundStyle(Color(hex: 0xD8C9BA)))
        }
        .buttonStyle(.plain)
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28).fill(Color.white)
            if let imageData, let image = ThumbnailCache.image(for: imageData) {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: 300, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 28))
            }
            if isProcessing { ProgressView() }
        }
        .frame(width: 300, height: 300)
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Theme.cardBorder, lineWidth: 2))
    }

    // MARK: - Processing

    private func startProcessing(_ item: PhotosPickerItem) {
        loadTask?.cancel()
        isProcessing = true
        loadTask = Task {
            guard let raw = try? await item.loadTransferable(type: Data.self) else {
                await MainActor.run { isProcessing = false }
                return
            }
            // 색칠용(풀 표시) + 그리드용(작은 썸네일)을 백그라운드에서 분리 생성
            let full = await Task.detached(priority: .userInitiated) {
                ImageDownsampler.thumbnailData(from: raw, maxPixel: 1400)
            }.value
            let thumb = await Task.detached(priority: .userInitiated) {
                ImageDownsampler.thumbnailData(from: raw, maxPixel: 480)
            }.value
            if Task.isCancelled { return }
            await MainActor.run {
                imageData = full
                thumbnailData = thumb
                isProcessing = false
            }
        }
    }
}
