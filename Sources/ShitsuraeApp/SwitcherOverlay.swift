import AppKit
@preconcurrency import ScreenCaptureKit
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
        let thumbnailSession = showThumbnails && SystemProbe.screenRecordingGranted()
            ? WindowThumbnailProvider.shared.beginSession()
            : nil
        let content = OverlayContent(
            candidates: session.candidates,
            selectedIndex: session.selectedIndex,
            thumbnailSession: thumbnailSession,
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
            thumbnailSession: hosting.rootView.thumbnailSession,
            onSelect: onSelect
        )
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        hosting = nil
    }
}

struct OverlayContent: View {
    let candidates: [SwitcherCandidate]
    let selectedIndex: Int
    let thumbnailSession: WindowThumbnailSession?
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        Button {
                            onSelect(index)
                        } label: {
                            CandidateCard(
                                candidate: candidate,
                                isSelected: index == selectedIndex,
                                thumbnailSession: thumbnailSession
                            )
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityLabel(candidateAccessibilityLabel(candidate))
                        .accessibilityValue(index == selectedIndex ? "Selected" : "")
                        .accessibilityHint("Switch to this window")
                        .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
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

    private func candidateAccessibilityLabel(_ candidate: SwitcherCandidate) -> String {
        let application = shortBundleID(candidate.bundleID)
        guard !candidate.title.isEmpty else {
            return application
        }
        return "\(application), \(candidate.title)"
    }
}

struct CandidateCard: View {
    let candidate: SwitcherCandidate
    let isSelected: Bool
    let thumbnailSession: WindowThumbnailSession?

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
            .task(id: thumbnailSession?.id) {
                guard let thumbnailSession else {
                    thumbnail = nil
                    return
                }
                thumbnail = thumbnailSession.placeholder(identity: candidate.identity)
                thumbnail = await thumbnailSession.captureFresh(identity: candidate.identity)
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
        shortBundleID(candidate.bundleID)
    }

    private var appIconImage: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate.bundleID)
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

    private final class CacheEntry {
        let image: NSImage
        let capturedAt: Date

        init(image: NSImage, capturedAt: Date) {
            self.image = image
            self.capturedAt = capturedAt
        }
    }

    private let cache = NSCache<NSString, CacheEntry>()
    private let placeholderTTL: TimeInterval
    private let now: () -> Date
    private let processStartTime: (Int) -> UInt64?

    init(
        placeholderTTL: TimeInterval = 1,
        now: @escaping () -> Date = Date.init,
        processStartTime: @escaping (Int) -> UInt64? = ProcessGenerationResolver.startTime(pid:)
    ) {
        self.placeholderTTL = placeholderTTL
        self.now = now
        self.processStartTime = processStartTime
    }

    static func cacheKey(for identity: WindowIdentity) -> String {
        "\(identity.pid):\(identity.processStartTime):\(identity.windowID):\(identity.bundleID)"
    }

    func beginSession(
        contentLoader: @escaping @MainActor () async -> SCShareableContent? = {
            try? await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        }
    ) -> WindowThumbnailSession {
        WindowThumbnailSession(provider: self, contentLoader: contentLoader)
    }

    func placeholder(identity: WindowIdentity) -> NSImage? {
        guard processStartTime(identity.pid) == identity.processStartTime else {
            return nil
        }
        let cacheKey = Self.cacheKey(for: identity) as NSString
        guard let cached = cache.object(forKey: cacheKey) else {
            return nil
        }
        let age = now().timeIntervalSince(cached.capturedAt)
        guard age >= 0, age <= placeholderTTL
        else {
            return nil
        }
        return cached.image
    }

    fileprivate func capture(
        identity: WindowIdentity,
        content: SCShareableContent
    ) async -> NSImage? {
        // An overlay candidate can outlive its process. Never serve a cached
        // image, or capture a newly reused PID/window ID, for the old process
        // generation.
        guard processStartTime(identity.pid) == identity.processStartTime,
            let scWindow = content.windows.first(where: {
                $0.windowID == CGWindowID(identity.windowID)
                    && Int($0.owningApplication?.processID ?? -1) == identity.pid
                    && $0.owningApplication?.bundleIdentifier == identity.bundleID
            })
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
        ), processStartTime(identity.pid) == identity.processStartTime else {
            return nil
        }

        let image = NSImage(cgImage: cgImage, size: .zero)
        cache.setObject(
            CacheEntry(image: image, capturedAt: now()),
            forKey: Self.cacheKey(for: identity) as NSString
        )
        return image
    }

    func storeForTesting(_ image: NSImage, identity: WindowIdentity, capturedAt: Date) {
        cache.setObject(
            CacheEntry(image: image, capturedAt: capturedAt),
            forKey: Self.cacheKey(for: identity) as NSString
        )
    }
}

/// A switcher session owns exactly one ScreenCaptureKit inventory snapshot.
/// Every card still requests a fresh screenshot; a sub-second cache entry is
/// only a placeholder while that capture is in flight.
@MainActor
final class WindowThumbnailSession: Identifiable {
    let id = UUID()

    private let provider: WindowThumbnailProvider
    private let contentTask: Task<SCShareableContent?, Never>

    init(
        provider: WindowThumbnailProvider,
        contentLoader: @escaping @MainActor () async -> SCShareableContent?
    ) {
        self.provider = provider
        contentTask = Task { await contentLoader() }
    }

    func placeholder(identity: WindowIdentity) -> NSImage? {
        provider.placeholder(identity: identity)
    }

    func captureFresh(identity: WindowIdentity) async -> NSImage? {
        guard let content = await contentTask.value else {
            return nil
        }
        return await provider.capture(identity: identity, content: content)
    }
}
