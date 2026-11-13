import AVKit
import SwiftUI
import UIKit

/// What the full-screen viewer shows.
enum MediaViewerItem: Identifiable {
    case image(URL?)
    case video(URL)

    var id: String {
        switch self {
        case .image(let url): "image|" + (url?.absoluteString ?? "")
        case .video(let url): "video|" + url.absoluteString
        }
    }
}

/// Full-screen photo (pinch / double-tap to zoom, drag down to close, save and share) or video player.
struct MediaViewer: View {
    let item: MediaViewerItem
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    @State private var saved = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(max(0.3, 1 - abs(dragOffset) / 400)).ignoresSafeArea()
            content
            controls
        }
        .statusBarHidden()
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .video(let url):
            VideoPlayerView(url: url).ignoresSafeArea()
        case .image(let url):
            Group {
                if let image {
                    ZoomableImage(image: image, onSwipeDown: { dismiss() }, dragOffset: $dragOffset)
                } else if failed {
                    Label("Không tải được ảnh", systemImage: "exclamationmark.triangle").foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .task { await load(url) }
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                if let image {
                    Button {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        saved = true
                    } label: {
                        Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Lưu vào Ảnh")
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Ảnh", image: Image(uiImage: image))) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold))
                            .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        }
        .opacity(dragOffset == 0 ? 1 : 0)
    }

    private func load(_ url: URL?) async {
        guard let url else { failed = true; return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let decoded = UIImage(data: data) { image = decoded } else { failed = true }
        } catch {
            failed = true
        }
    }
}

/// UIScrollView-backed zoom: pinch, double-tap to zoom in/out, and a downward swipe at 1× closes the viewer.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onSwipeDown: () -> Void
    @Binding var dragOffset: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = LayoutScrollView()
        scroll.onLayout = { [weak scroll, coordinator = context.coordinator] in
            if let scroll { coordinator.layout(in: scroll) }
        }
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.delegate = context.coordinator
        scroll.addGestureRecognizer(pan)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.layout(in: scroll)
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomableImage
        weak var imageView: UIImageView?
        private var lastSize: CGSize = .zero

        init(_ parent: ZoomableImage) { self.parent = parent }

        func layout(in scroll: UIScrollView) {
            guard let imageView, scroll.bounds.size != .zero, scroll.bounds.size != lastSize else { return }
            lastSize = scroll.bounds.size
            scroll.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: scroll.bounds.size)
            scroll.contentSize = scroll.bounds.size
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }

        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView, scroll.zoomScale <= 1.01 else { return }
            let y = gesture.translation(in: scroll).y
            switch gesture.state {
            case .changed:
                parent.dragOffset = y
                imageView?.transform = CGAffineTransform(translationX: 0, y: y)
            case .ended, .cancelled:
                if abs(y) > 120 || abs(gesture.velocity(in: scroll).y) > 900 {
                    parent.onSwipeDown()
                } else {
                    UIView.animate(withDuration: 0.2) { self.imageView?.transform = .identity }
                    parent.dragOffset = 0
                }
            default:
                break
            }
        }

        /// Only vertical drags at 1× start the close gesture; everything else is the scroll view's.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, let scroll = pan.view as? UIScrollView else { return true }
            let velocity = pan.velocity(in: scroll)
            return scroll.zoomScale <= 1.01 && abs(velocity.y) > abs(velocity.x)
        }
    }
}

/// Reports layout passes so the image can be fitted once the scroll view has its final size.
final class LayoutScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// System video player (AVPlayerViewController) that starts playing right away.
struct VideoPlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
    }
}

/// Plays one voice message; publishes play state and progress for the bubble.
@MainActor @Observable
final class VoicePlayer {
    private(set) var playing = false
    private(set) var progress: Double = 0
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var total: Double = 0

    func toggle(url: URL, duration: Int) {
        if playing { player?.pause(); playing = false; return }
        if player == nil {
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            let newPlayer = AVPlayer(url: url)
            total = Double(duration)
            observer = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
                                                         queue: .main) { [weak self] time in
                let seconds = time.seconds
                MainActor.assumeIsolated { self?.tick(seconds) }
            }
            player = newPlayer
        }
        player?.play()
        playing = true
    }

    private func tick(_ seconds: Double) {
        if total <= 0, let item = player?.currentItem, item.duration.seconds.isFinite { total = item.duration.seconds }
        progress = total > 0 ? min(1, seconds / total) : 0
        if progress >= 0.999 {
            playing = false
            progress = 0
            player?.pause()
            player?.seek(to: .zero)
        }
    }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player = nil
        playing = false
        progress = 0
    }
}

/// Voice message: play / pause with progress.
struct VoiceBubble: View {
    let url: URL?
    let duration: Int
    let isMine: Bool
    @State private var voice = VoicePlayer()

    var body: some View {
        HStack(spacing: 10) {
            Button { if let url { voice.toggle(url: url, duration: duration) } } label: {
                Image(systemName: voice.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
            }
            .disabled(url == nil)
            ProgressView(value: voice.progress).frame(width: 110)
            Text(MobileMessageRow.clock(duration)).font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(isMine ? .white : .primary)
        .tint(isMine ? .white : .accentColor)
        .background(isMine ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        .onDisappear { voice.stop() }
    }
}
