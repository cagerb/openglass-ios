import SwiftUI
import SwiftData

struct GalleryView: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(GlassesState.self) private var glasses
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CaptureRecord.timestamp, order: .reverse) private var captureRecords: [CaptureRecord]

    @State private var selectedCapture: Capture?
    @State private var isDownloading = false
    @State private var downloadProgress: (completed: Int, total: Int) = (0, 0)
    @State private var showExportConfirmation = false

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 4)
    ]

    private let store = LocalStore()

    var body: some View {
        NavigationStack {
            Group {
                if captureRecords.isEmpty {
                    ContentUnavailableView(
                        "No Captures",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Connect your glasses and sync to see photos and videos here.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(captureRecords, id: \.assetId) { record in
                                captureTile(record)
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
                        Button {
                            Task { await downloadAll() }
                        } label: {
                            Label("Download All", systemImage: "arrow.down.circle")
                        }
                        .disabled(bluetooth.connectionState != .authenticated)

                        Button {
                            showExportConfirmation = true
                        } label: {
                            Label("Export All to Photos", systemImage: "square.and.arrow.up")
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
        }
    }

    // MARK: - Capture tile

    @ViewBuilder
    private func captureTile(_ record: CaptureRecord) -> some View {
        let capture = record.toCapture(baseDirectory: store.mediaDirectory)

        Button {
            selectedCapture = capture
            if !capture.isDownloaded {
                Task { await downloadSingle(capture) }
            }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                // Thumbnail or placeholder
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

                // Type badge
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

    // MARK: - Download

    private func downloadSingle(_ capture: Capture) async {
        // Placeholder: actual download would use MediaDownloader + SoftAPManager
        // This wires up the UI flow for when those are connected
    }

    private func downloadAll() async {
        isDownloading = true
        downloadProgress = (0, captureRecords.count)

        // This will be wired to MediaDownloader.downloadBatch()
        // For now, track progress state
        for i in 0..<captureRecords.count {
            try? await Task.sleep(for: .milliseconds(100))
            downloadProgress = (i + 1, captureRecords.count)
        }

        isDownloading = false
    }

    private func exportAll() async {
        let captures = captureRecords.map { $0.toCapture(baseDirectory: store.mediaDirectory) }
        do {
            try await store.exportAllToPhotos(captures: captures) { completed, total in
                // Progress callback
            }
        } catch {
            // Handle error in production
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
