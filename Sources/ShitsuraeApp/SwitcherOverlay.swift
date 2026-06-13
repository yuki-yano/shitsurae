import AppKit
import ScreenCaptureKit
import SwiftUI
import ShitsuraeCore

/// Floating switcher / cycle overlay. The panel is non-activating and never
/// hides on deactivate — it must not steal focus from the frontmost app.
@MainActor
final class SwitcherOverlayController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<OverlayContent>?
    private let onSelect: (Int) -> Void

    init(onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
    }

    func show(session: HotkeyManager.OverlaySession, showThumbnails: Bool) {
        let content = OverlayContent(
            candidates: session.candidates,
            selectedIndex: session.selectedIndex,
            showThumbnails: showThumbnails && SystemProbe.screenRecordingGranted(),
            onSelect: onSelect
        )

        if panel == nil {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
            panel.isMovableByWindowBackground = false
            self.panel = panel
        }

        guard let panel else { return }

        let hosting = NSHostingView(rootView: content)
        self.hosting = hosting
        panel.contentView = hosting

        // Cap to the screen: with many candidates the card row scrolls
        // horizontally instead of running off the display.
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let fitting = hosting.fittingSize
        let size = CGSize(
            width: min(fitting.width, max(320, screenFrame.width - 80)),
            height: fitting.height
        )
        let origin = CGPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func update(session: HotkeyManager.OverlaySession) {
        guard let hosting else { return }
        hosting.rootView = OverlayContent(
            candidates: session.candidates,
            selectedIndex: session.selectedIndex,
            showThumbnails: hosting.rootView.showThumbnails,
            onSelect: onSelect
        )
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

struct OverlayContent: View {
    let candidates: [SwitcherCandidate]
    let selectedIndex: Int
    let showThumbnails: Bool
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        CandidateCard(
                            candidate: candidate,
                            isSelected: index == selectedIndex,
                            showThumbnail: showThumbnails
                        )
                        .id(index)
                        .onTapGesture {
                            onSelect(index)
                        }
                    }
                }
                .padding(16)
            }
            .onAppear {
                proxy.scrollTo(selectedIndex, anchor: .center)
            }
            .onChange(of: selectedIndex) { _, newValue in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(8)
    }
}

struct CandidateCard: View {
    let candidate: SwitcherCandidate
    let isSelected: Bool
    let showThumbnail: Bool

    @State private var thumbnail: NSImage?

    private static let tileWidth: CGFloat = 240
    private static let tileHeight: CGFloat = 150

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: Self.tileWidth, height: Self.tileHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        appIcon
                            .frame(width: Self.tileWidth, height: Self.tileHeight)
                    }
                }

                // Small app icon badge over the thumbnail for recognition.
                if thumbnail != nil, let icon = appIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .padding(4)
                }
            }
            .task(id: candidate.windowID) {
                guard showThumbnail, let windowID = candidate.windowID else { return }
                thumbnail = await WindowThumbnailProvider.shared.thumbnail(windowID: windowID)
            }

            HStack(spacing: 5) {
                if let quickKey = candidate.quickKey {
                    Text(quickKey)
                        .font(.callout.monospaced().bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                }
                Text(candidate.title.isEmpty ? appName : candidate.title)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: Self.tileWidth - 30)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.35) : Color.clear)
        )
    }

    private var appName: String {
        candidate.bundleID.map(shortBundleID) ?? ""
    }

    private var appIconImage: NSImage? {
        guard let bundleID = candidate.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var appIcon: some View {
        Group {
            if let icon = appIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Window thumbnail capture via ScreenCaptureKit (requires the optional
/// Screen Recording permission; callers fall back to the app icon).
@MainActor
final class WindowThumbnailProvider {
    static let shared = WindowThumbnailProvider()

    private let cache = NSCache<NSNumber, NSImage>()

    func thumbnail(windowID: UInt32) async -> NSImage? {
        if let cached = cache.object(forKey: NSNumber(value: windowID)) {
            return cached
        }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ),
            let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(windowID) })
        else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        // Thumbnail-sized capture keeps this cheap (2x the 240pt tile).
        let scale = 480.0 / max(scWindow.frame.width, 1)
        configuration.width = Int(scWindow.frame.width * scale)
        configuration.height = Int(scWindow.frame.height * scale)
        configuration.showsCursor = false

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) else {
            return nil
        }

        let image = NSImage(cgImage: cgImage, size: .zero)
        cache.setObject(image, forKey: NSNumber(value: windowID))
        return image
    }
}
