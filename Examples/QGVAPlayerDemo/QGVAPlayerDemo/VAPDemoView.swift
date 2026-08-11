import QGVAPlayer
import SwiftUI
import UIKit

struct VAPDemoView: View {
    @State private var resources: [VAPResource] = []

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(resources) { resource in
                    VAPResourceCell(resource: resource)
                }
            }
            .padding(12)
        }
        .navigationTitle("VAP Demo")
        .onAppear {
            resources = VAPResourceLoader.loadResources()
        }
        .overlay {
            if resources.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("未找到 VAP 资源")
                        .font(.headline)
                    Text("请确认 Resources/vap 下的 mp4 已加入 Demo target")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding()
            }
        }
    }
}

private struct VAPResourceCell: View {
    let resource: VAPResource

    @State private var playbackID = 0
    @State private var isVisible = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black.opacity(0.04)

                VAPPlayerView(
                    fileURL: resource.url,
                    playbackID: playbackID,
                    isActive: isVisible,
                    repeatCount: -1,
                    isMuted: true,
                    contentMode: QGVAPWrapViewContentMode(rawValue: 1) ?? QGVAPWrapViewContentMode(rawValue: 0)!,
                    onStatusChange: { status = $0 }
                )
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear {
                isVisible = true
                playbackID += 1
            }
            .onDisappear {
                isVisible = false
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(resource.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospacedDigit()

                if !status.isEmpty {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct VAPPlayerView: UIViewRepresentable {
    let fileURL: URL
    let playbackID: Int
    let isActive: Bool
    let repeatCount: Int
    let isMuted: Bool
    let contentMode: QGVAPWrapViewContentMode
    let onStatusChange: (String) -> Void

    func makeUIView(context: Context) -> QGVAPWrapView {
        let view = QGVAPWrapView()
        view.backgroundColor = .clear
        view.autoDestoryAfterFinish = false
        view.contentMode = contentMode
        return view
    }

    func updateUIView(_ uiView: QGVAPWrapView, context: Context) {
        context.coordinator.onStatusChange = onStatusChange
        uiView.contentMode = contentMode

        guard isActive else {
            uiView.stopHWDMP4()
            return
        }

        guard context.coordinator.lastPlaybackID != playbackID else { return }
        context.coordinator.lastPlaybackID = playbackID

        uiView.stopHWDMP4()
        uiView.setMute(isMuted)
        uiView.playHWDMP4(fileURL.path, repeatCount: repeatCount, delegate: context.coordinator)
        context.coordinator.sendStatus("播放中")
    }

    static func dismantleUIView(_ uiView: QGVAPWrapView, coordinator: Coordinator) {
        uiView.stopHWDMP4()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onStatusChange: onStatusChange)
    }

    final class Coordinator: NSObject, VAPWrapViewDelegate {
        var lastPlaybackID = 0
        var onStatusChange: (String) -> Void

        init(onStatusChange: @escaping (String) -> Void) {
            self.onStatusChange = onStatusChange
        }

        func sendStatus(_ status: String) {
            DispatchQueue.main.async {
                self.onStatusChange(status)
            }
        }

        func vapWrap_viewDidStartPlayMP4(_ container: UIView) {
            sendStatus("已开始")
        }

        func vapWrap_viewDidFinishPlayMP4(_ totalFrameCount: Int, view container: UIView) {
            sendStatus("完成 \(totalFrameCount) 帧")
        }

        func vapWrap_viewDidStopPlayMP4(_ lastFrameIndex: Int, view container: UIView) {
            sendStatus("已停止")
        }

        func vapWrap_viewDidFailPlayMP4(_ error: Error) {
            sendStatus("失败：\(error.localizedDescription)")
        }
    }
}

private struct VAPResource: Identifiable {
    let url: URL

    var id: String { url.lastPathComponent }

    var displayName: String {
        String(url.deletingPathExtension().lastPathComponent.prefix(8))
    }
}

private enum VAPResourceLoader {
    static func loadResources(bundle: Bundle = .main) -> [VAPResource] {
        let subdirectoryURLs = [
            bundle.urls(forResourcesWithExtension: "mp4", subdirectory: "Resource/vap"),
            bundle.urls(forResourcesWithExtension: "mp4", subdirectory: "vap")
        ]
        .compactMap { $0 }
        .flatMap { $0 }

        let rootURLs = bundle.urls(forResourcesWithExtension: "mp4", subdirectory: nil) ?? []

        let uniqueURLs = Dictionary(
            grouping: subdirectoryURLs + rootURLs,
            by: { $0.lastPathComponent }
        )
        .compactMap { $0.value.first }

        return uniqueURLs
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(VAPResource.init(url:))
    }

}
#Preview {
    NavigationView {
        VAPDemoView()
    }
}
