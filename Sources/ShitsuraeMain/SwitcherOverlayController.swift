@preconcurrency import AppKit
import Foundation
import ScreenCaptureKit
import ShitsuraeCore
import SwiftUI

private final class WeakSwitcherOverlayControllerBox: @unchecked Sendable {
    weak var controller: SwitcherOverlayController?

    init(controller: SwitcherOverlayController) {
        self.controller = controller
    }
}

private struct SwitcherOverlayComponents: @unchecked Sendable {
    let panel: NSPanel
    let viewModel: SwitcherOverlayViewModel
}

final class SwitcherOverlayController {
    private let panel: NSPanel
    private let viewModel: SwitcherOverlayViewModel
    private var iconCache: [String: NSImage] = [:]
    private var previewCache: [String: NSImage] = [:]
    private var pendingPreviewIDs: Set<String> = []
    private var previewCaptureMaxPixels: CGFloat = 0
    private var showsWindowThumbnails = false

    init() {
        let components: SwitcherOverlayComponents
        if Thread.isMainThread {
            components = MainActor.assumeIsolated {
                Self.makeComponentsOnMain()
            }
        } else {
            var tmp: SwitcherOverlayComponents?
            DispatchQueue.main.sync {
                tmp = MainActor.assumeIsolated {
                    Self.makeComponentsOnMain()
                }
            }
            guard let built = tmp else {
                fatalError("Failed to initialize switcher overlay")
            }
            components = built
        }

        self.panel = components.panel
        self.viewModel = components.viewModel
    }

    func show(candidates: [SwitcherCandidate], selectedIndex: Int) {
        let managerBox = WeakSwitcherOverlayControllerBox(controller: self)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                managerBox.controller?.showOnMain(candidates: candidates, selectedIndex: selectedIndex)
            }
            return
        }

        let snapshot = candidates
        DispatchQueue.main.async {
            guard let controller = managerBox.controller else {
                return
            }
            MainActor.assumeIsolated {
                controller.showOnMain(candidates: snapshot, selectedIndex: selectedIndex)
            }
        }
    }

    func hide() {
        let managerBox = WeakSwitcherOverlayControllerBox(controller: self)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                managerBox.controller?.hideOnMain()
            }
            return
        }

        DispatchQueue.main.async {
            guard let controller = managerBox.controller else {
                return
            }
            MainActor.assumeIsolated {
                controller.hideOnMain()
            }
        }
    }

    func setShowsWindowThumbnails(_ enabled: Bool) {
        let managerBox = WeakSwitcherOverlayControllerBox(controller: self)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                managerBox.controller?.setShowsWindowThumbnailsOnMain(enabled)
            }
            return
        }

        DispatchQueue.main.async {
            guard let controller = managerBox.controller else {
                return
            }
            MainActor.assumeIsolated {
                controller.setShowsWindowThumbnailsOnMain(enabled)
            }
        }
    }

    @MainActor
    private func showOnMain(candidates: [SwitcherCandidate], selectedIndex: Int) {
        let isInitialPresentation = !panel.isVisible
        let shouldAnimateSelection = panel.isVisible
        let displayFrame = panelDisplayFrame()
        let metrics = makeMetrics(
            candidateCount: candidates.count,
            displayFrame: displayFrame
        )

        self.viewModel.set(
            candidates: candidates,
            selectedIndex: selectedIndex,
            previews: self.previewCache,
            icons: self.iconCache,
            metrics: metrics,
            shouldAnimateSelection: shouldAnimateSelection
        )
        self.updatePanelFrame(
            metrics: metrics,
            displayFrame: displayFrame,
            forceReposition: !self.panel.isVisible
        )

        if !self.panel.isVisible {
            self.panel.orderFrontRegardless()
        }

        self.prefetchAssets(
            for: candidates,
            metrics: metrics,
            forceRefreshVisiblePreviews: isInitialPresentation
        )
    }

    @MainActor
    private func hideOnMain() {
        panel.orderOut(nil)
        viewModel.resetPresentationState()
    }

    @MainActor
    private func setShowsWindowThumbnailsOnMain(_ enabled: Bool) {
        guard showsWindowThumbnails != enabled else {
            return
        }

        showsWindowThumbnails = enabled
        guard !enabled else {
            return
        }

        previewCache.removeAll(keepingCapacity: true)
        pendingPreviewIDs.removeAll(keepingCapacity: true)
        previewCaptureMaxPixels = 0
        viewModel.clearPreviews()
    }

    @MainActor
    private func prefetchAssets(
        for candidates: [SwitcherCandidate],
        metrics: SwitcherOverlayMetrics,
        forceRefreshVisiblePreviews: Bool
    ) {
        self.prefetchIcons(for: candidates)
        self.prefetchWindowPreviews(
            for: candidates,
            maxPixels: desiredPreviewCapturePixels(for: metrics),
            forceRefreshVisiblePreviews: forceRefreshVisiblePreviews
        )
    }

    @MainActor
    private func prefetchIcons(for candidates: [SwitcherCandidate]) {
        var iconAdded = false
        for candidate in candidates where self.iconCache[candidate.id] == nil {
            guard let icon = makeIcon(for: candidate) else {
                continue
            }
            self.iconCache[candidate.id] = icon
            iconAdded = true
        }
        if iconAdded {
            self.viewModel.setIcons(iconCache, for: Set(candidates.map(\.id)))
        }

        trimCacheIfNeeded()
    }

    @MainActor
    private func prefetchWindowPreviews(
        for candidates: [SwitcherCandidate],
        maxPixels: CGFloat,
        forceRefreshVisiblePreviews: Bool
    ) {
        guard showsWindowThumbnails else {
            return
        }

        let effectiveMaxPixels = min(
            SwitcherOverlayLayout.thumbnailMaxPixels,
            max(SwitcherOverlayLayout.minPreviewCapturePixels, maxPixels)
        )
        if effectiveMaxPixels > previewCaptureMaxPixels + 32 {
            previewCaptureMaxPixels = effectiveMaxPixels
            previewCache.removeAll(keepingCapacity: true)
            pendingPreviewIDs.removeAll(keepingCapacity: true)
        } else if previewCaptureMaxPixels <= 0 {
            previewCaptureMaxPixels = effectiveMaxPixels
        }

        let jobs = SwitcherPreviewCapturePlanner.plannedJobs(
            candidates: candidates,
            cachedPreviewIDs: Set(self.previewCache.keys),
            pendingPreviewIDs: self.pendingPreviewIDs,
            thumbnailsEnabled: showsWindowThumbnails,
            forceRefreshVisiblePreviews: forceRefreshVisiblePreviews
        ).reduce(into: [String: CGWindowID]()) { partialResult, item in
            partialResult[item.key] = CGWindowID(item.value)
        }

        guard !jobs.isEmpty else {
            return
        }

        for candidateID in jobs.keys {
            self.pendingPreviewIDs.insert(candidateID)
        }

        let managerBox = WeakSwitcherOverlayControllerBox(controller: self)
        let requestedMaxPixels = effectiveMaxPixels
        Task.detached(priority: .userInitiated) {
            let previews = await SwitcherOverlayController.captureWindowPreviews(
                jobs: jobs,
                maxPixels: requestedMaxPixels
            )
            await MainActor.run {
                guard let controller = managerBox.controller else {
                    return
                }

                for candidateID in jobs.keys {
                    controller.pendingPreviewIDs.remove(candidateID)
                }

                guard controller.showsWindowThumbnails else {
                    return
                }

                if requestedMaxPixels + 1 < controller.previewCaptureMaxPixels {
                    return
                }

                if !previews.isEmpty {
                    for (candidateID, image) in previews {
                        controller.previewCache[candidateID] = image
                    }
                    controller.viewModel.setPreviews(controller.previewCache, for: Set(jobs.keys))
                }
            }
        }
    }

    private static func captureWindowPreviews(
        jobs: [String: CGWindowID],
        maxPixels: CGFloat
    ) async -> [String: NSImage] {
        guard !jobs.isEmpty else {
            return [:]
        }

        guard let shareableContent = try? await SCShareableContent.current else {
            return [:]
        }

        let windowsByID = Dictionary(uniqueKeysWithValues: shareableContent.windows.map { ($0.windowID, $0) })
        var results: [String: NSImage] = [:]
        for (candidateID, windowID) in jobs {
            guard let window = windowsByID[windowID],
                  let image = await captureWindowPreview(window: window, maxPixels: maxPixels)
            else {
                continue
            }
            results[candidateID] = image
        }
        return results
    }

    private static func captureWindowPreview(window: SCWindow, maxPixels: CGFloat) async -> NSImage? {
        let frame = window.frame
        let maxDimension = max(frame.width, frame.height)
        guard maxDimension > 0 else {
            return nil
        }

        let scale = min(1.0, maxPixels / maxDimension)
        let config = SCStreamConfiguration()
        config.width = Int(max(1, (frame.width * scale).rounded()))
        config.height = Int(max(1, (frame.height * scale).rounded()))
        config.showsCursor = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        ) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    @MainActor
    private func desiredPreviewCapturePixels(for metrics: SwitcherOverlayMetrics) -> CGFloat {
        let scale = panel.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        let base = max(metrics.cardWidth, metrics.previewHeight)
        let desired = ceil(base * scale * 3.0)
        return min(
            SwitcherOverlayLayout.thumbnailMaxPixels,
            max(SwitcherOverlayLayout.minPreviewCapturePixels, desired)
        )
    }

    @MainActor
    private func makeIcon(for candidate: SwitcherCandidate) -> NSImage? {
        guard let bundleID = candidate.bundleID else {
            return nil
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = running.icon
        {
            return icon
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    @MainActor
    private func trimCacheIfNeeded() {
        if previewCache.count > SwitcherOverlayLayout.cacheLimit {
            previewCache.removeAll(keepingCapacity: true)
            pendingPreviewIDs.removeAll(keepingCapacity: true)
        }
        if iconCache.count > SwitcherOverlayLayout.cacheLimit {
            iconCache.removeAll(keepingCapacity: true)
        }
    }

    @MainActor
    private func updatePanelFrame(
        metrics: SwitcherOverlayMetrics,
        displayFrame: NSRect,
        forceReposition: Bool
    ) {
        let targetWidth = metrics.panelWidth
        let targetHeight = metrics.panelHeight
        let currentFrame = panel.frame
        if !forceReposition,
           abs(currentFrame.width - targetWidth) < 0.5,
           abs(currentFrame.height - targetHeight) < 0.5
        {
            return
        }

        let newFrame = NSRect(
            x: round(displayFrame.midX - targetWidth / 2),
            y: round(displayFrame.midY - targetHeight / 2),
            width: targetWidth,
            height: targetHeight
        )
        panel.setFrame(newFrame, display: true)
    }

    @MainActor
    private func makeMetrics(candidateCount: Int, displayFrame: NSRect) -> SwitcherOverlayMetrics {
        let effectiveCount = max(candidateCount, SwitcherOverlayLayout.minLayoutCards)
        let visibleCards = min(effectiveCount, SwitcherOverlayLayout.maxVisibleCards)

        let widthLimit = max(620, floor(displayFrame.width - 24))
        let heightLimit = max(210, floor(displayFrame.height - 24))

        let preferredWidth = min(
            widthLimit,
            max(
                SwitcherOverlayLayout.minPanelWidth,
                floor(displayFrame.width * SwitcherOverlayLayout.panelWidthRatio)
            )
        )
        let preferredHeight = min(
            heightLimit,
            max(
                SwitcherOverlayLayout.minPanelHeight,
                floor(displayFrame.height * SwitcherOverlayLayout.panelHeightRatio)
            )
        )

        let panelPadding = min(
            SwitcherOverlayLayout.maxPanelPadding,
            max(
                SwitcherOverlayLayout.minPanelPadding,
                floor(min(preferredWidth, preferredHeight) * 0.06)
            )
        )
        let horizontalPadding = panelPadding
        let verticalPadding = panelPadding
        let cardSpacing = max(12, floor(preferredWidth * 0.012))
        let desiredCardWidth = min(
            SwitcherOverlayLayout.maxCardWidth,
            max(
                SwitcherOverlayLayout.minCardWidth,
                floor(displayFrame.width * SwitcherOverlayLayout.cardWidthRatio)
            )
        )
        let desiredCardHeight = min(
            SwitcherOverlayLayout.maxCardHeight,
            max(
                SwitcherOverlayLayout.minCardHeight,
                floor(desiredCardWidth * SwitcherOverlayLayout.cardHeightRatio)
            )
        )
        let desiredPanelWidth = horizontalPadding * 2
            + CGFloat(visibleCards) * desiredCardWidth
            + CGFloat(max(visibleCards - 1, 0)) * cardSpacing
        let panelWidth = min(
            preferredWidth,
            max(SwitcherOverlayLayout.minPanelWidth, desiredPanelWidth)
        )
        let desiredPanelHeight = verticalPadding * 2 + desiredCardHeight
        let panelHeight = min(
            heightLimit,
            min(preferredHeight, max(SwitcherOverlayLayout.minPanelHeight, desiredPanelHeight))
        )

        let cardWidthRaw = (panelWidth
            - horizontalPadding * 2
            - CGFloat(max(visibleCards - 1, 0)) * cardSpacing
        ) / CGFloat(visibleCards)
        let cardWidth = min(
            SwitcherOverlayLayout.maxCardWidth,
            max(SwitcherOverlayLayout.minCardWidth, floor(cardWidthRaw))
        )
        let cardHeight = min(
            SwitcherOverlayLayout.maxCardHeight,
            max(SwitcherOverlayLayout.minCardHeight, floor(panelHeight - verticalPadding * 2))
        )
        let previewHeight = max(92, min(cardHeight - 48, floor(cardHeight * 0.60)))

        return SwitcherOverlayMetrics(
            panelWidth: panelWidth,
            panelHeight: panelHeight,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            cardSpacing: cardSpacing,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            previewHeight: previewHeight,
            maxVisibleCards: SwitcherOverlayLayout.maxVisibleCards
        )
    }

    @MainActor
    private func panelDisplayFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        if let matchingScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return matchingScreen.visibleFrame
        }
        return NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
    }

    @MainActor
    private static func makeComponentsOnMain() -> SwitcherOverlayComponents {
        let viewModel = SwitcherOverlayViewModel()
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SwitcherOverlayLayout.initialPanelWidth,
                height: SwitcherOverlayLayout.initialPanelHeight
            ),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        let hostingView = NSHostingView(rootView: SwitcherOverlayView(viewModel: viewModel))

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        hostingView.frame = NSRect(
            origin: .zero,
            size: panel.contentRect(forFrameRect: panel.frame).size
        )
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        return SwitcherOverlayComponents(panel: panel, viewModel: viewModel)
    }
}

private enum SwitcherOverlayLayout {
    static let maxVisibleCards = 6
    static let minLayoutCards = 1
    static let panelWidthRatio: CGFloat = 0.72
    static let panelHeightRatio: CGFloat = 0.31
    static let minPanelWidth: CGFloat = 420
    static let minPanelHeight: CGFloat = 196
    static let minCardWidth: CGFloat = 176
    static let maxCardWidth: CGFloat = 330
    static let minCardHeight: CGFloat = 142
    static let maxCardHeight: CGFloat = 240
    static let cardHeightRatio: CGFloat = 0.74
    static let cardWidthRatio: CGFloat = 0.136
    static let minPanelPadding: CGFloat = 16
    static let maxPanelPadding: CGFloat = 20
    static let initialPanelWidth: CGFloat = 820
    static let initialPanelHeight: CGFloat = 256
    static let thumbnailMaxPixels: CGFloat = 2_048
    static let minPreviewCapturePixels: CGFloat = 960
    static let cacheLimit = 160
}

private struct SwitcherOverlayMetrics {
    let panelWidth: CGFloat
    let panelHeight: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let cardSpacing: CGFloat
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let previewHeight: CGFloat
    let maxVisibleCards: Int

    static let initial = SwitcherOverlayMetrics(
        panelWidth: SwitcherOverlayLayout.initialPanelWidth,
        panelHeight: SwitcherOverlayLayout.initialPanelHeight,
        horizontalPadding: 18,
        verticalPadding: 18,
        cardSpacing: 10,
        cardWidth: 236,
        cardHeight: 174,
        previewHeight: 104,
        maxVisibleCards: SwitcherOverlayLayout.maxVisibleCards
    )
}

private final class SwitcherOverlayViewModel: ObservableObject {
    @Published private(set) var candidates: [SwitcherCandidate] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var previewsByID: [String: NSImage] = [:]
    @Published private(set) var iconsByID: [String: NSImage] = [:]
    @Published private(set) var metrics = SwitcherOverlayMetrics.initial
    @Published private(set) var shouldAnimateSelection = false

    func set(
        candidates: [SwitcherCandidate],
        selectedIndex: Int,
        previews: [String: NSImage],
        icons: [String: NSImage],
        metrics: SwitcherOverlayMetrics,
        shouldAnimateSelection: Bool
    ) {
        self.shouldAnimateSelection = shouldAnimateSelection
        self.candidates = candidates
        self.selectedIndex = selectedIndex
        self.metrics = metrics
        let ids = Set(candidates.map(\.id))
        previewsByID = previews.filter { ids.contains($0.key) }
        iconsByID = icons.filter { ids.contains($0.key) }
    }

    func resetPresentationState() {
        shouldAnimateSelection = false
        candidates = []
        selectedIndex = 0
    }

    func clearPreviews() {
        previewsByID = [:]
    }

    func setPreviews(_ previews: [String: NSImage], for candidateIDs: Set<String>) {
        previewsByID = previews.filter { candidateIDs.contains($0.key) }
    }

    func setIcons(_ icons: [String: NSImage], for candidateIDs: Set<String>) {
        iconsByID = icons.filter { candidateIDs.contains($0.key) }
    }

    func select(candidateID: String) {
        NotificationCenter.default.post(
            name: ShortcutManager.switcherOverlaySelectionNotification,
            object: nil,
            userInfo: [ShortcutManager.switcherOverlaySelectionCandidateIDKey: candidateID]
        )
    }
}

private struct SwitcherOverlayView: View {
    @ObservedObject var viewModel: SwitcherOverlayViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.18, green: 0.20, blue: 0.24).opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.24), lineWidth: 1.2)
                )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: viewModel.metrics.cardSpacing) {
                    ForEach(Array(viewModel.candidates.enumerated()), id: \.element.id) { index, candidate in
                        SwitcherCandidateCardView(
                            candidate: candidate,
                            isSelected: index == viewModel.selectedIndex,
                            preview: viewModel.previewsByID[candidate.id],
                            icon: viewModel.iconsByID[candidate.id],
                            metrics: viewModel.metrics,
                            onSelect: { viewModel.select(candidateID: candidate.id) }
                        )
                    }
                }
                .padding(.horizontal, viewModel.metrics.horizontalPadding)
                .padding(.vertical, viewModel.metrics.verticalPadding)
            }
            .scrollDisabled(viewModel.candidates.count <= viewModel.metrics.maxVisibleCards)
        }
        .clipShape(.rect(cornerRadius: 22))
        .padding(0.5)
        .animation(
            viewModel.shouldAnimateSelection ? .snappy(duration: 0.18) : nil,
            value: viewModel.selectedIndex
        )
    }
}

private struct SwitcherCandidateCardView: View {
    let candidate: SwitcherCandidate
    let isSelected: Bool
    let preview: NSImage?
    let icon: NSImage?
    let metrics: SwitcherOverlayMetrics
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compactLayout ? 7 : 10) {
            headerRow
            bundleRow
            windowLikePreview
                .frame(height: metrics.previewHeight)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1.1)
                )
        }
        .padding(compactLayout ? 10 : 14)
        .frame(width: metrics.cardWidth, height: metrics.cardHeight, alignment: .topLeading)
        .background(Color.white.opacity(isSelected ? 0.34 : 0.2))
        .clipShape(.rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? Color.white.opacity(0.95) : Color.white.opacity(0.22),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .scaleEffect(isSelected ? 1.028 : 1.0)
        .shadow(
            color: Color.black.opacity(isSelected ? 0.24 : 0.13),
            radius: isSelected ? 16 : 9,
            y: isSelected ? 6 : 3
        )
        .contentShape(.rect(cornerRadius: 14))
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(candidate.title)")
    }

    private var compactLayout: Bool {
        metrics.cardWidth < 220
    }

    private var headerRow: some View {
        HStack(spacing: compactLayout ? 6 : 8) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "rectangle.on.rectangle")
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: compactLayout ? 18 : 20, height: compactLayout ? 18 : 20)

            Text(candidate.title)
                .font(.system(size: compactLayout ? 14 : 17, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 0)

            if let quickKey = candidate.quickKey {
                Text(quickKey.uppercased())
                    .font(.system(size: compactLayout ? 10 : 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(.horizontal, compactLayout ? 5 : 7)
                    .padding(.vertical, compactLayout ? 2 : 3)
                    .background(Color.white.opacity(0.14))
                    .clipShape(.rect(cornerRadius: 6))
            }
        }
        .foregroundStyle(Color.white)
    }

    private var bundleRow: some View {
        Group {
            if let bundleID = candidate.bundleID {
                Text(bundleID)
                    .font(.system(size: compactLayout ? 11 : 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(1)
            } else {
                Text(" ")
                    .font(.system(size: compactLayout ? 11 : 12, weight: .regular))
            }
        }
    }

    private var windowLikePreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: compactLayout ? 4 : 5) {
                Circle()
                    .fill(Color.red.opacity(0.8))
                    .frame(width: compactLayout ? 5 : 6, height: compactLayout ? 5 : 6)
                Circle()
                    .fill(Color.yellow.opacity(0.82))
                    .frame(width: compactLayout ? 5 : 6, height: compactLayout ? 5 : 6)
                Circle()
                    .fill(Color.green.opacity(0.82))
                    .frame(width: compactLayout ? 5 : 6, height: compactLayout ? 5 : 6)

                Spacer(minLength: 0)

                Text(candidate.source == .window ? "Window" : "Session")
                    .font(.system(size: compactLayout ? 8 : 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, compactLayout ? 7 : 8)
            .frame(height: compactLayout ? 19 : 21)
            .background(Color.white.opacity(0.18))

            ZStack {
                if let preview {
                    Color.black.opacity(0.1)
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFit()
                } else {
                    LinearGradient(
                        colors: [Color.white.opacity(0.2), Color.black.opacity(0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Group {
                        if let icon {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .padding(compactLayout ? 16 : 24)
                                .opacity(0.56)
                        } else {
                            Image(systemName: "macwindow")
                                .font(.system(size: compactLayout ? 26 : 34))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                    }
                }
            }
        }
    }
}
