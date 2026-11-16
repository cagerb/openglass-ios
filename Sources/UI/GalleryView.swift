import SwiftUI
import SwiftData

struct GalleryView: View {
    @Environment(WearablesManager.self) private var wearables
    @Environment(GlassesState.self) private var glasses
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CaptureRecord.timestamp, order: .reverse) private var captureRecords: [CaptureRecord]

    @State private var isDownloading = false
    @State private var downloadProgress: (completed: Int, total: Int) = (0, 0)
    @State private var showExportConfirmation = false
    @State private var selectedPhotoIndex: Int?

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 4)
    ]

    private let store = LocalStore()

    var body: some View {
        NavigationStack {
            Group {
                if wearables.capturedPhotos.isEmpty && captureRecords.isEmpty {
                    ContentUnavailableView(
                        "No Captures",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Connect your glasses and use the camera to capture photos, or sync stored media.")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if !wearables.capturedPhotos.isEmpty {
                                livePhotosSection
                            }

                            if !captureRecords.isEmpty {
                                storedMediaSection
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .navigationTitle("Gallery")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if wearables.isStreaming {
                            Button {
                                _ = wearables.capturePhoto()
                            } label: {
                                Label("Take Photo", systemImage: "camera")
                            }
                        }

                        if !captureRecords.isEmpty {
                            Button {
                                showExportConfirmation = true
                            } label: {
                                Label("Export All to Photos", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .overlay {
                if isDownloading {
                    downloadOverlay
                }
            }
            .alert("Export to Photos", isPresented: $showExportConfirmation) {
                Button("Export") {
                    Task { await exportAll() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Export all downloaded captures to your Photos library?")
            }
            .sheet(item: $selectedPhotoIndex) { index in
                photoDetail(index: index)
            }
        }
    }

    // MARK: - Live photos from SDK camera

    private var livePhotosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Captured This Session")
                    .font(.headline)
                    .padding(.horizontal, 8)
                Spacer()
                Text("\(wearables.capturedPhotos.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(wearables.capturedPhotos.enumerated()), id: \.offset) { index, photoData in
                    if let uiImage = UIImage(data: photoData) {
                        Button {
                            selectedPhotoIndex = index
                        } label: {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(1, contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Stored media from SoftAP sync

    private var storedMediaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Synced from Glasses")
                .font(.headline)
                .padding(.horizontal, 8)

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(captureRecords, id: \.assetId) { record in
                    captureTile(record)
                }
            }
        }
    }

    // MARK: - Capture tile

    @ViewBuilder
    private func captureTile(_ record: CaptureRecord) -> some View {
        let capture = record.toCapture(baseDirectory: store.mediaDirectory)

        Button {
            // Future: open detail view
        } label: {
            ZStack(alignment: .bottomTrailing) {
                if let thumbURL = capture.thumbnailURL,
                   FileManager.default.fileExists(atPath: thumbURL.path) {
                    AsyncImage(url: thumbURL) { image in
                        image
                            .resizable()
                            .aspectRatio(1, contentMode: .fill)
                    } placeholder: {
                        thumbnailPlaceholder(capture)
                    }
                } else {
                    thumbnailPlaceholder(capture)
                }

                HStack(spacing: 2) {
                    Image(systemName: capture.type.systemImage)
                        .font(.caption2)
                    if capture.isDownloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                .padding(4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                .padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func thumbnailPlaceholder(_ capture: Capture) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                Image(systemName: capture.type.systemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
    }

    // MARK: - Photo detail

    private func photoDetail(index: Int) -> some View {
        NavigationStack {
            if index < wearables.capturedPhotos.count,
               let uiImage = UIImage(data: wearables.capturedPhotos[index]) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .navigationTitle("Photo \(index + 1)")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                saveToPhotos(wearables.capturedPhotos[index])
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                            }
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                selectedPhotoIndex = nil
                            }
                        }
                    }
            }
        }
    }

    // MARK: - Export

    private func saveToPhotos(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }

    private func exportAll() async {
        let captures = captureRecords.map { $0.toCapture(baseDirectory: store.mediaDirectory) }
        do {
            try await store.exportAllToPhotos(captures: captures) { _, _ in }
        } catch {
            // Handle error
        }
    }

    // MARK: - Download overlay

    private var downloadOverlay: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(downloadProgress.completed), total: Double(max(downloadProgress.total, 1)))
                .progressViewStyle(.linear)

            Text("\(downloadProgress.completed) of \(downloadProgress.total)")
                .font(.subheadline)
                .monospacedDigit()

            Button("Cancel") {
                isDownloading = false
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(32)
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
