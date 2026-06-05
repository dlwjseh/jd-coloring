import SwiftUI
import SwiftData
import PhotosUI

/// 도안 만들기 시트 — 사진 선택 → 미리보기 → 앨범 선택 → 저장. (사진을 가공 없이 그대로 도안으로 등록)
struct TemplateUploadView: View {
    /// 선택 가능한 앨범 목록(생성순).
    var albums: [Album]
    /// 기본 선택 앨범(현재 보고 있는 앨범, 미분류면 nil).
    var initialAlbum: Album?
    var onCancel: () -> Void
    /// (도안 이름, 색칠용 이미지, 그리드 표시용 썸네일, 소속 앨범[nil=미분류])
    var onSave: (String, Data, Data, Album?) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var imageData: Data?       // 색칠용(다운샘플) + 미리보기
    @State private var thumbnailData: Data?    // 그리드 표시용
    @State private var templateName = ""
    @State private var selectedAlbum: Album?
    @State private var albumInitialized = false
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

            // 앨범 선택 — 기본값 = 현재 앨범. 비우면(미분류) 미분류로 저장. (디자인 §30)
            albumPickerRow

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
                        onSave(templateName.trimmingCharacters(in: .whitespaces), img, thumb, selectedAlbum)
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
        .frame(width: 510)
        .background(RoundedRectangle(cornerRadius: 40).fill(Theme.card))
        .shadow(color: Theme.softShadow, radius: 24, x: 0, y: 10)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            startProcessing(item)
        }
        .onAppear {
            // 기본 선택 앨범을 1회만 주입(시트 재오픈 대비 가드).
            if !albumInitialized {
                selectedAlbum = initialAlbum
                albumInitialized = true
            }
        }
        .onDisappear {
            loadTask?.cancel()
            templateName = ""
        }
    }

    // MARK: - Subviews

    /// 앨범 선택 줄 — 좌측 "앨범" 라벨 + 우측 드롭다운(Menu). 항목: 앨범 + 미분류.
    private var albumPickerRow: some View {
        HStack(spacing: 16) {
            Text("앨범")
                .font(Theme.rounded(16, weight: .bold))
                .foregroundStyle(Theme.ink)
            Menu {
                ForEach(albums, id: \.persistentModelID) { album in
                    Button {
                        selectedAlbum = album
                    } label: {
                        if selectedAlbum?.persistentModelID == album.persistentModelID {
                            Label(album.name, systemImage: "checkmark")
                        } else {
                            Text(album.name)
                        }
                    }
                }
                Button {
                    selectedAlbum = nil
                } label: {
                    if selectedAlbum == nil {
                        Label("미분류", systemImage: "checkmark")
                    } else {
                        Text("미분류")
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(selectedAlbum?.name ?? "미분류")
                        .font(Theme.rounded(17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.subText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                // "앨범" 라벨 옆 남은 가로 영역을 꽉 채움(디자인 §30): 이름 좌측, 셰브런 우측.
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.coral, lineWidth: 1.5))
            }
            .menuStyle(.automatic)
            .accessibilityLabel("앨범")
            .accessibilityValue(selectedAlbum?.name ?? "미분류")
        }
        // 이름 필드와 좌우 라인 맞춤(콘텐츠 풀폭): "앨범" 라벨은 왼쪽 끝, 선택 필드는 오른쪽 끝.
        .frame(maxWidth: .infinity)
    }

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
