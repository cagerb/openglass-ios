import SwiftUI
import SwiftData

struct GalleryView: View {
    @Environment(GlassesController.self) private var controller
    @Environment(GlassesState.self) private var glasses
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CaptureRecord.timestamp, order: .reverse) private var captureRecords: [CaptureRecord]

    @State private var isDownloading = false
    @State private var downloadProgress: (completed: Int, total: Int) = (0, 0)
    @State private var showExportConfirmation = false
    @State private var savingHandle: String?

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 4)
    ]

    private let store = LocalStore()

    private var bleCaptures: [CaptureEntry] { controller.captures }
    private var hasAnyContent: Bool { !bleCaptures.isEmpty || !captureRecords.isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if hasAnyContent {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if !bleCaptures.isEmpty {
                                onGlassesSection
                            }
                            if !captureRecords.isEmpty {
                                downloadedSection
                            }
                        }
                        .padding(4)
                    }
                } else {
                    ContentUnavailableView(
                        "No Captures",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Connect to your glasses to see photos and videos stored on the device.")
                    )
                }
            }
            .navigationTitle("Gallery")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !bleCaptures.isEmpty {
                            Button {
                                controller.refreshCaptures()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
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
        }
    }

    // MARK: - On Glasses (BLE-enumerated captures)

    private var onGlassesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("On Glasses")
                    .font(.headline)
                    .padding(.horizontal, 8)
                Spacer()
                Text("\(bleCaptures.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(bleCaptures, id: \.handle) { entry in
                    bleTile(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func bleTile(_ entry: CaptureEntry) -> some View {
        let isPhoto = entry.kind == CaptureType.photo.rawValue
        let totalSize = entry.assets.reduce(0 as UInt64) { $0 + $1.sizeBytes }
        let isSaving = savingHandle == entry.handle

        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fill)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: isPhoto ? "photo" : "video")
                            .font(.title3)
                            .foregroundStyle(.secondary)

                        if totalSize > 0 {
                            Text(formatBytes(totalSize))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

            Button {
                savingHandle = entry.handle
                controller.requestCaptureDownload(handle: entry.handle)
            } label: {
                Image(systemName: isSaving ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.body)
                    .foregroundStyle(isSaving ? .green : .blue)
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Downloaded (SwiftData captures)

    private var downloadedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloaded")
                    .font(.headline)
                    .padding(.horizontal, 8)
                Spacer()
                Text("\(captureRecords.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(captureRecords, id: \.assetId) { record in
                    captureTile(record)
                }
            }
        }
    }

    // MARK: - Capture tile (downloaded)

    @ViewBuilder
    private func captureTile(_ record: CaptureRecord) -> some View {
        let capture = record.toCapture(baseDirectory: store.mediaDirectory)

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

    // MARK: - Export

    private func exportAll() async {
        let captures = captureRecords.map { $0.toCapture(baseDirectory: store.mediaDirectory) }
        do {
            try await store.exportAllToPhotos(captures: captures) { _, _ in }
        } catch {
            // Handle error
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else {
            return String(format: "%.0f KB", Double(bytes) / 1024)
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
