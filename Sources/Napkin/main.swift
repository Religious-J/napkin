import AppKit
import UniformTypeIdentifiers

enum PenColor: CaseIterable {
    case black
    case blue
    case red
    case green

    var color: NSColor {
        switch self {
        case .black:
            return .black
        case .blue:
            return .systemBlue
        case .red:
            return .systemRed
        case .green:
            return .systemGreen
        }
    }

    var displayName: String {
        switch self {
        case .black:
            return "Primary Pen"
        case .blue:
            return "Blue Pen"
        case .red:
            return "Red Pen"
        case .green:
            return "Green Pen"
        }
    }
}

enum DrawingTool: Equatable {
    case pen(PenColor)
    case eraser
    case text

    var color: NSColor {
        switch self {
        case .pen(let penColor):
            return penColor.color
        case .eraser:
            return .white
        case .text:
            return .black
        }
    }

    var width: CGFloat {
        switch self {
        case .pen:
            return 4
        case .eraser:
            return 28
        case .text:
            return 0
        }
    }

    var displayName: String {
        switch self {
        case .pen(let penColor):
            return penColor.displayName
        case .eraser:
            return "Eraser"
        case .text:
            return "Text"
        }
    }
}

enum DefaultAppearance: String {
    case light
    case dark

    private static let storageKey = "defaultAppearance"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            storageKey: Self.light.rawValue
        ])
    }

    static var stored: DefaultAppearance {
        get {
            let rawValue = UserDefaults.standard.string(forKey: storageKey) ?? Self.light.rawValue
            return DefaultAppearance(rawValue: rawValue) ?? .light
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }

    var isDarkMode: Bool {
        self == .dark
    }
}

struct Stroke {
    let points: [CGPoint]
    let tool: DrawingTool
    let width: CGFloat
}

struct TextItem {
    let text: String
    let origin: CGPoint
    let penColor: PenColor
    let fontSize: CGFloat
}

enum CanvasItem {
    case stroke(Stroke)
    case text(TextItem)
}

final class WhiteboardView: NSView {
    private enum HistoryAction {
        case add(CanvasItem)
        case clear([CanvasItem])
    }

    private var items: [CanvasItem] = []
    private var undoHistory: [HistoryAction] = []
    private var redoHistory: [HistoryAction] = []
    private var currentStroke: [CGPoint] = []
    private var toolPreviewPoint: CGPoint?
    private var autoscrollAnchorPoint: CGPoint?
    private var autoscrollCurrentPoint: CGPoint?
    private var autoscrollTimer: Timer?

    var onHistoryChanged: (() -> Void)?
    var onToolChanged: (() -> Void)?
    var onThemeChanged: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    var canUndoStroke: Bool { !undoHistory.isEmpty }
    var canRedoStroke: Bool { !redoHistory.isEmpty }
    var canClear: Bool { !items.isEmpty || !currentStroke.isEmpty }
    private(set) var isDarkMode = false
    private(set) var activeTool: DrawingTool = .pen(.black)
    private(set) var lastPenColor: PenColor = .black
    private(set) var eraserWidth: CGFloat = DrawingTool.eraser.width
    private(set) var textFontSize: CGFloat = 24
    private var activeTextView: InlineTextView?
    var canvasBackgroundColor: NSColor {
        isDarkMode ? Self.darkCanvasColor : Self.lightCanvasColor
    }
    var primaryPenColor: NSColor {
        isDarkMode ? Self.darkPrimaryPenColor : Self.lightPrimaryPenColor
    }

    private static let lightCanvasColor = NSColor.white
    private static let darkCanvasColor = NSColor(calibratedWhite: 0.06, alpha: 1)
    private static let lightPrimaryPenColor = NSColor(calibratedWhite: 0.08, alpha: 1)
    private static let darkPrimaryPenColor = NSColor(calibratedWhite: 0.94, alpha: 1)
    private static let scrollZoomSensitivity: CGFloat = 0.02
    private static let eraserScrollSensitivity: CGFloat = 0.4
    private static let minEraserWidth: CGFloat = 8
    private static let maxEraserWidth: CGFloat = 96
    private static let textFontScrollSensitivity: CGFloat = 0.3
    private static let minTextFontSize: CGFloat = 12
    private static let maxTextFontSize: CGFloat = 72
    private static let textBoxWidth: CGFloat = 280

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = canvasBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        canvasBackgroundColor.setFill()
        bounds.fill()

        draw(items)
        drawCurrentStroke()
        drawToolPreview()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        guard activeTool != .text else {
            beginTextSession(at: point)
            return
        }

        currentStroke = [point]
        toolPreviewPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeTool != .text else { return }

        let point = convert(event.locationInWindow, from: nil)
        currentStroke.append(point)
        toolPreviewPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard activeTool != .text else { return }

        let point = convert(event.locationInWindow, from: nil)
        currentStroke.append(point)
        let stroke = Stroke(points: currentStroke, tool: activeTool, width: effectiveWidth(for: activeTool))
        let item = CanvasItem.stroke(stroke)

        items.append(item)
        undoHistory.append(.add(item))
        redoHistory = []
        currentStroke = []
        toolPreviewPoint = point
        needsDisplay = true
        onHistoryChanged?()
    }

    override func mouseMoved(with event: NSEvent) {
        updateAutoscrollPoint(with: event)
        updateToolPreview(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        beginAutoscroll(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        updateAutoscrollPoint(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        endAutoscroll()
    }

    override func otherMouseDown(with event: NSEvent) {
        beginAutoscroll(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        updateAutoscrollPoint(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        endAutoscroll()
    }

    override func mouseEntered(with event: NSEvent) {
        updateToolPreview(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        toolPreviewPoint = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard
            event.modifierFlags.contains(.command),
            event.scrollingDeltaY != 0,
            let scrollView = enclosingScrollView
        else {
            super.scrollWheel(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let factor = exp(event.scrollingDeltaY * Self.scrollZoomSensitivity)
        let targetMagnification = scrollView.magnification * factor
        let clampedMagnification = min(
            max(targetMagnification, scrollView.minMagnification),
            scrollView.maxMagnification
        )

        scrollView.setMagnification(clampedMagnification, centeredAt: point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        for area in trackingAreas {
            removeTrackingArea(area)
        }

        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        ))
    }

    @objc
    func undoStroke(_ sender: Any?) {
        guard let action = undoHistory.popLast() else { return }

        switch action {
        case .add:
            _ = items.popLast()
        case .clear(let clearedItems):
            items = clearedItems
        }

        redoHistory.append(action)
        needsDisplay = true
        onHistoryChanged?()
    }

    @objc
    func redoStroke(_ sender: Any?) {
        guard let action = redoHistory.popLast() else { return }

        switch action {
        case .add(let item):
            items.append(item)
        case .clear:
            items = []
        }

        undoHistory.append(action)
        needsDisplay = true
        onHistoryChanged?()
    }

    @objc
    func clear(_ sender: Any?) {
        let clearedItems = items

        items = []
        currentStroke = []
        toolPreviewPoint = nil
        activeTextView?.removeFromSuperview()
        activeTextView = nil
        if !clearedItems.isEmpty {
            undoHistory.append(.clear(clearedItems))
            redoHistory = []
        }
        needsDisplay = true
        onHistoryChanged?()
    }

    func pngData(in exportRect: NSRect) -> Data? {
        let rect = exportRect.intersection(bounds).integral

        guard !rect.isEmpty, let bitmap = bitmapImageRepForCachingDisplay(in: rect) else {
            return nil
        }

        let savedPreviewPoint = toolPreviewPoint
        toolPreviewPoint = nil
        cacheDisplay(in: rect, to: bitmap)
        toolPreviewPoint = savedPreviewPoint

        return bitmap.representation(using: .png, properties: [:])
    }

    func trimmedFullCanvasExportRect(padding: CGFloat) -> NSRect? {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        var hasPoints = false

        for item in items {
            switch item {
            case .stroke(let stroke):
                let radius = stroke.width / 2

                for point in stroke.points {
                    minX = min(minX, point.x - radius)
                    minY = min(minY, point.y - radius)
                    maxX = max(maxX, point.x + radius)
                    maxY = max(maxY, point.y + radius)
                    hasPoints = true
                }
            case .text(let textItem):
                let size = textItem.text.size(withAttributes: [.font: NSFont.systemFont(ofSize: textItem.fontSize)])
                let rect = NSRect(origin: textItem.origin, size: size)

                minX = min(minX, rect.minX)
                minY = min(minY, rect.minY)
                maxX = max(maxX, rect.maxX)
                maxY = max(maxY, rect.maxY)
                hasPoints = true
            }
        }

        guard hasPoints else { return nil }

        let paddedMinX = max(0, floor(minX - padding))
        let paddedMinY = max(0, floor(minY - padding))
        let paddedMaxX = min(bounds.width, ceil(maxX + padding))
        let paddedMaxY = min(bounds.height, ceil(maxY + padding))

        return NSRect(
            x: paddedMinX,
            y: paddedMinY,
            width: paddedMaxX - paddedMinX,
            height: paddedMaxY - paddedMinY
        )
    }

    func setActiveTool(_ tool: DrawingTool) {
        if tool != .text, activeTextView != nil {
            window?.makeFirstResponder(self)
        }

        if case .pen(let penColor) = tool {
            lastPenColor = penColor
        }

        activeTool = tool
        needsDisplay = true
        onToolChanged?()
    }

    func setDarkMode(_ enabled: Bool) {
        guard isDarkMode != enabled else { return }

        isDarkMode = enabled
        layer?.backgroundColor = canvasBackgroundColor.cgColor
        needsDisplay = true
        onThemeChanged?()
    }

    func renderedColor(for tool: DrawingTool) -> NSColor {
        switch tool {
        case .pen(.black):
            return primaryPenColor
        case .pen(let penColor):
            return penColor.color
        case .eraser:
            return canvasBackgroundColor
        case .text:
            return primaryPenColor
        }
    }

    func effectiveWidth(for tool: DrawingTool) -> CGFloat {
        switch tool {
        case .eraser:
            return eraserWidth
        case .pen:
            return tool.width
        case .text:
            return textFontSize
        }
    }

    func adjustEraserWidth(byScrollDelta delta: CGFloat) {
        let proposedWidth = eraserWidth + delta * Self.eraserScrollSensitivity
        eraserWidth = min(max(proposedWidth, Self.minEraserWidth), Self.maxEraserWidth)
    }

    func adjustTextFontSize(byScrollDelta delta: CGFloat) {
        let proposedSize = textFontSize + delta * Self.textFontScrollSensitivity
        textFontSize = min(max(proposedSize, Self.minTextFontSize), Self.maxTextFontSize)

        if let activeTextView {
            activeTextView.font = .systemFont(ofSize: textFontSize)
            resizeActiveTextView()
        }
    }

    private func beginAutoscroll(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        currentStroke = []
        toolPreviewPoint = nil
        autoscrollAnchorPoint = point
        autoscrollCurrentPoint = point
        needsDisplay = true

        autoscrollTimer?.invalidate()
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performAutoscrollStep()
            }
        }
        autoscrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateAutoscrollPoint(with event: NSEvent) {
        guard autoscrollTimer != nil else { return }
        autoscrollCurrentPoint = convert(event.locationInWindow, from: nil)
    }

    private func endAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        autoscrollAnchorPoint = nil
        autoscrollCurrentPoint = nil
    }

    private func performAutoscrollStep() {
        guard
            let anchor = autoscrollAnchorPoint,
            let current = autoscrollCurrentPoint,
            let scrollView = enclosingScrollView
        else {
            endAutoscroll()
            return
        }

        let deltaX = current.x - anchor.x
        let deltaY = current.y - anchor.y
        let distance = hypot(deltaX, deltaY)
        let deadZone: CGFloat = 18

        guard distance > deadZone else { return }

        let speed = min((distance - deadZone) * 0.12, 18)
        let step = NSPoint(
            x: deltaX / distance * speed,
            y: deltaY / distance * speed
        )
        let clipView = scrollView.contentView
        let currentOrigin = clipView.bounds.origin
        let maxOrigin = NSPoint(
            x: max(0, bounds.width - clipView.bounds.width),
            y: max(0, bounds.height - clipView.bounds.height)
        )
        let nextOrigin = NSPoint(
            x: min(max(currentOrigin.x + step.x, 0), maxOrigin.x),
            y: min(max(currentOrigin.y + step.y, 0), maxOrigin.y)
        )

        guard nextOrigin != currentOrigin else { return }

        clipView.scroll(to: nextOrigin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func updateToolPreview(with event: NSEvent) {
        guard autoscrollTimer == nil else { return }
        toolPreviewPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    private func draw(_ items: [CanvasItem]) {
        for item in items {
            switch item {
            case .stroke(let stroke):
                draw(points: stroke.points, tool: stroke.tool, width: stroke.width)
            case .text(let textItem):
                drawText(textItem)
            }
        }
    }

    private func drawText(_ item: TextItem) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: item.fontSize),
            .foregroundColor: renderedColor(for: .pen(item.penColor))
        ]

        NSAttributedString(string: item.text, attributes: attributes).draw(at: item.origin)
    }

    private func drawCurrentStroke() {
        draw(points: currentStroke, tool: activeTool, width: effectiveWidth(for: activeTool))
    }

    private func draw(points: [CGPoint], tool: DrawingTool, width: CGFloat) {
        guard let firstPoint = points.first else { return }

        let strokeColor = renderedColor(for: tool)

        if points.allSatisfy({ $0 == firstPoint }) {
            let radius = width / 2
            let dotRect = NSRect(
                x: firstPoint.x - radius,
                y: firstPoint.y - radius,
                width: width,
                height: width
            )

            strokeColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return
        }

        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: firstPoint)

        if points.count == 1 {
            path.line(to: firstPoint)
        } else {
            for point in points.dropFirst() {
                path.line(to: point)
            }
        }

        strokeColor.setStroke()
        path.stroke()
    }

    private func drawToolPreview() {
        guard activeTool != .text, let point = toolPreviewPoint else { return }

        let width = effectiveWidth(for: activeTool)
        let radius = width / 2
        let previewRect = NSRect(
            x: point.x - radius,
            y: point.y - radius,
            width: width,
            height: width
        )
        let previewPath = NSBezierPath(ovalIn: previewRect)
        let previewColor = activeTool == .eraser
            ? primaryPenColor
            : renderedColor(for: activeTool)

        previewColor.withAlphaComponent(0.12).setFill()
        previewPath.fill()
        previewColor.withAlphaComponent(0.35).setStroke()
        previewPath.lineWidth = 1
        previewPath.stroke()
    }

    private func beginTextSession(at point: CGPoint) {
        window?.makeFirstResponder(self)

        let textView = InlineTextView(frame: NSRect(
            origin: point,
            size: NSSize(width: Self.textBoxWidth, height: textFontSize + 8)
        ))
        textView.string = ""
        textView.font = .systemFont(ofSize: textFontSize)
        textView.textColor = renderedColor(for: .pen(lastPenColor))
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.onResignFirstResponder = { [weak self] in
            self?.commitActiveTextSession()
        }

        addSubview(textView)
        activeTextView = textView
        window?.makeFirstResponder(textView)
    }

    private func resizeActiveTextView() {
        guard
            let activeTextView,
            let layoutManager = activeTextView.layoutManager,
            let textContainer = activeTextView.textContainer
        else { return }

        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let newHeight = max(textFontSize + 8, usedHeight)

        if activeTextView.frame.height != newHeight {
            activeTextView.setFrameSize(NSSize(width: activeTextView.frame.width, height: newHeight))
        }
    }

    private func commitActiveTextSession() {
        guard let textView = activeTextView else { return }

        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = textView.frame.origin

        textView.removeFromSuperview()
        activeTextView = nil

        guard !text.isEmpty else {
            needsDisplay = true
            return
        }

        let item = CanvasItem.text(TextItem(
            text: text,
            origin: origin,
            penColor: lastPenColor,
            fontSize: textFontSize
        ))

        items.append(item)
        undoHistory.append(.add(item))
        redoHistory = []
        needsDisplay = true
        onHistoryChanged?()
    }
}

extension WhiteboardView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        resizeActiveTextView()
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }

        window?.makeFirstResponder(self)
        return true
    }
}

final class CanvasClipView: NSClipView {
    private static let invisibleCursor = NSCursor(
        image: NSImage(size: NSSize(width: 1, height: 1)),
        hotSpot: .zero
    )

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.invisibleCursor)
    }
}

final class ToolbarView: NSVisualEffectView {
    var onScroll: ((NSEvent) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }
}

final class InlineTextView: NSTextView {
    var onResignFirstResponder: (() -> Void)?

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()

        if didResign {
            onResignFirstResponder?()
        }

        return didResign
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let minMagnification: CGFloat = 0.1
    private static let maxMagnification: CGFloat = 4.0
    private static let zoomStep: CGFloat = 1.25

    private let canvasSize = NSSize(width: 5000, height: 5000)
    private let minimumContentSize = NSSize(width: 640, height: 360)
    private var window: NSWindow?
    private var canvas: WhiteboardView?
    private var settingsButton: NSButton?
    private var darkModeButton: NSButton?
    private var undoButton: NSButton?
    private var redoButton: NSButton?
    private var clearButton: NSButton?
    private var blackPenButton: NSButton?
    private var bluePenButton: NSButton?
    private var redPenButton: NSButton?
    private var greenPenButton: NSButton?
    private var eraserButton: NSButton?
    private var textButton: NSButton?
    private var toolStatusLabel: NSTextField?
    private var undoMenuItem: NSMenuItem?
    private var redoMenuItem: NSMenuItem?
    private var scrollView: NSScrollView?
    private var settingsWindow: NSWindow?
    private var lightModePreferenceButton: NSButton?
    private var darkModePreferenceButton: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DefaultAppearance.registerDefaults()
        configureMenu()

        let canvas = WhiteboardView(frame: NSRect(origin: .zero, size: canvasSize))
        let contentView = makeContentView(canvas: canvas)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Napkin"
        window.contentMinSize = minimumContentSize
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        window.contentView = contentView

        self.window = window
        self.canvas = canvas
        canvas.setDarkMode(DefaultAppearance.stored.isDarkMode)
        window.contentView?.layoutSubtreeIfNeeded()
        centerCanvasView()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)

        canvas.onHistoryChanged = { [weak self] in
            self?.updateHistoryControls()
        }
        canvas.onToolChanged = { [weak self] in
            self?.updateToolControls()
        }
        canvas.onThemeChanged = { [weak self] in
            self?.updateThemeControls()
        }
        updateHistoryControls()
        updateToolControls()
        updateThemeControls()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.centerCanvasView()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc
    private func showAbout(_ sender: Any?) {
        let repositoryURL = "https://github.com/alex-k03/napkin"
        let credits = NSMutableAttributedString(
            string: "Created by Alexander Kharchenko.\nCopyright (c) 2026 Alexander Kharchenko.\n\nA tiny macOS whiteboard for quick thinking, sketching, and ink-first notes.\n\nLocal-only. No accounts. No telemetry.\nMIT licensed.\n\n\(repositoryURL)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        credits.addAttribute(
            .link,
            value: repositoryURL,
            range: (credits.string as NSString).range(of: repositoryURL)
        )

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Napkin",
            .applicationVersion: "0.1.0",
            .version: "Build 1",
            .credits: credits
        ])
    }

    @objc
    private func undoStroke(_ sender: Any?) {
        canvas?.undoStroke(nil)
        updateHistoryControls()
    }

    @objc
    private func redoStroke(_ sender: Any?) {
        canvas?.redoStroke(nil)
        updateHistoryControls()
    }

    @objc
    private func clearCanvas(_ sender: Any?) {
        canvas?.clear(nil)
        updateHistoryControls()
    }

    @objc
    private func toggleDarkMode(_ sender: Any?) {
        canvas?.setDarkMode(!(canvas?.isDarkMode ?? false))
        updateThemeControls()
        window?.makeFirstResponder(canvas)
    }

    @objc
    private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }

        updateSettingsControls()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func selectDefaultAppearance(_ sender: NSButton) {
        DefaultAppearance.stored = sender.tag == 1 ? .dark : .light
        updateSettingsControls()
        canvas?.setDarkMode(DefaultAppearance.stored.isDarkMode)
        updateThemeControls()
    }

    @objc
    private func exportCanvas(_ sender: Any?) {
        guard let window, let canvas else { return }

        let panel = NSSavePanel()
        panel.title = "Export Whiteboard"
        panel.nameFieldStringValue = "whiteboard.png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let fullCanvasCheckbox = NSButton(
            checkboxWithTitle: "Save full canvas",
            target: nil,
            action: nil
        )
        fullCanvasCheckbox.toolTip = "Exports the smallest rectangle containing all drawing, plus a little padding."
        panel.accessoryView = makeSavePanelAccessory(with: fullCanvasCheckbox)

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }

            do {
                let exportRect = fullCanvasCheckbox.state == .on
                    ? canvas.trimmedFullCanvasExportRect(padding: 50) ?? canvas.visibleRect
                    : canvas.visibleRect

                guard let data = canvas.pngData(in: exportRect) else {
                    throw CocoaError(.fileWriteUnknown)
                }

                try data.write(to: url)
            } catch {
                self?.showExportError(error)
            }
        }
    }

    private func showExportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not export the whiteboard."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func makeSavePanelAccessory(with checkbox: NSButton) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 44))

        checkbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(checkbox)

        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    private func makeSettingsWindow() -> NSWindow {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 156))
        let titleLabel = NSTextField(labelWithString: "Default Mode")
        let detailLabel = NSTextField(labelWithString: "Choose the canvas appearance Napkin uses when it opens.")
        let lightButton = NSButton(
            radioButtonWithTitle: "Light",
            target: self,
            action: #selector(AppDelegate.selectDefaultAppearance(_:))
        )
        let darkButton = NSButton(
            radioButtonWithTitle: "Dark",
            target: self,
            action: #selector(AppDelegate.selectDefaultAppearance(_:))
        )
        let optionsStack = NSStackView(views: [lightButton, darkButton])

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        lightButton.tag = 0
        darkButton.tag = 1
        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 8

        for view in [titleLabel, detailLabel, optionsStack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            optionsStack.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 16),
            optionsStack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor)
        ])

        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = contentView
        window.isReleasedWhenClosed = false

        lightModePreferenceButton = lightButton
        darkModePreferenceButton = darkButton

        return window
    }

    private func updateSettingsControls() {
        let defaultAppearance = DefaultAppearance.stored

        lightModePreferenceButton?.state = defaultAppearance == .light ? .on : .off
        darkModePreferenceButton?.state = defaultAppearance == .dark ? .on : .off
    }

    private func centerCanvasView() {
        guard let canvas, let scrollView else { return }

        let clipView = scrollView.contentView
        let visibleSize = clipView.bounds.size
        let centeredOrigin = NSPoint(
            x: max(0, (canvas.bounds.width - visibleSize.width) / 2),
            y: max(0, (canvas.bounds.height - visibleSize.height) / 2)
        )

        clipView.scroll(to: centeredOrigin)
        scrollView.reflectScrolledClipView(clipView)
    }

    @objc
    private func toggleFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(nil)
    }

    @objc
    private func zoomIn(_ sender: Any?) {
        setMagnification((scrollView?.magnification ?? 1) * Self.zoomStep)
    }

    @objc
    private func zoomOut(_ sender: Any?) {
        setMagnification((scrollView?.magnification ?? 1) / Self.zoomStep)
    }

    @objc
    private func resetZoom(_ sender: Any?) {
        setMagnification(1)
    }

    private func setMagnification(_ value: CGFloat) {
        guard let scrollView else { return }

        let clampedValue = min(max(value, Self.minMagnification), Self.maxMagnification)
        let visibleCenter = NSPoint(
            x: scrollView.documentVisibleRect.midX,
            y: scrollView.documentVisibleRect.midY
        )

        scrollView.setMagnification(clampedValue, centeredAt: visibleCenter)
    }

    private func handleToolbarScroll(_ event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }

        switch canvas?.activeTool {
        case .eraser:
            canvas?.adjustEraserWidth(byScrollDelta: event.scrollingDeltaY)
        case .text:
            canvas?.adjustTextFontSize(byScrollDelta: event.scrollingDeltaY)
        default:
            return
        }
    }

    @objc
    private func selectBlackPen(_ sender: Any?) {
        selectPen(.black)
    }

    @objc
    private func selectBluePen(_ sender: Any?) {
        selectPen(.blue)
    }

    @objc
    private func selectRedPen(_ sender: Any?) {
        selectPen(.red)
    }

    @objc
    private func selectGreenPen(_ sender: Any?) {
        selectPen(.green)
    }

    private func selectPen(_ color: PenColor) {
        canvas?.setActiveTool(.pen(color))
        window?.makeFirstResponder(canvas)
    }

    @objc
    private func selectEraser(_ sender: Any?) {
        canvas?.setActiveTool(.eraser)
        window?.makeFirstResponder(canvas)
    }

    @objc
    private func selectText(_ sender: Any?) {
        canvas?.setActiveTool(.text)
        window?.makeFirstResponder(canvas)
    }

    private func makeContentView(canvas: WhiteboardView) -> NSView {
        let contentView = NSView()
        let scrollView = NSScrollView()
        let toolbar = makeToolbar()

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsetsZero
        scrollView.allowsMagnification = true
        scrollView.minMagnification = Self.minMagnification
        scrollView.maxMagnification = Self.maxMagnification
        scrollView.contentView = CanvasClipView()
        scrollView.documentView = canvas
        self.scrollView = scrollView

        contentView.addSubview(scrollView)
        contentView.addSubview(toolbar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 56)
        ])

        return contentView
    }

    private func makeToolbar() -> NSView {
        let toolbar = ToolbarView()
        toolbar.material = .underWindowBackground
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.onScroll = { [weak self] event in
            self?.handleToolbarScroll(event)
        }

        let appControlsStack = NSStackView()
        appControlsStack.orientation = .horizontal
        appControlsStack.alignment = .centerY
        appControlsStack.spacing = 10
        appControlsStack.translatesAutoresizingMaskIntoConstraints = false

        let drawingControlsStack = NSStackView()
        drawingControlsStack.orientation = .horizontal
        drawingControlsStack.alignment = .centerY
        drawingControlsStack.spacing = 10
        drawingControlsStack.translatesAutoresizingMaskIntoConstraints = false

        let settingsButton = makeToolbarButton(
            symbolName: "gearshape",
            accessibilityDescription: "Settings",
            action: #selector(AppDelegate.showSettings(_:))
        )
        let darkModeButton = makeToolbarButton(
            symbolName: "moon",
            accessibilityDescription: "Dark Mode",
            action: #selector(AppDelegate.toggleDarkMode(_:))
        )
        let undoButton = makeToolbarButton(
            symbolName: "arrow.uturn.backward",
            accessibilityDescription: "Undo",
            action: #selector(AppDelegate.undoStroke(_:))
        )
        let redoButton = makeToolbarButton(
            symbolName: "arrow.uturn.forward",
            accessibilityDescription: "Redo",
            action: #selector(AppDelegate.redoStroke(_:))
        )
        let clearButton = makeToolbarButton(
            symbolName: "trash",
            accessibilityDescription: "Clear",
            action: #selector(AppDelegate.clearCanvas(_:))
        )
        let blackPenButton = makeColorButton(
            color: canvas?.primaryPenColor ?? .black,
            accessibilityDescription: "Primary Pen",
            action: #selector(AppDelegate.selectBlackPen(_:))
        )
        let bluePenButton = makeColorButton(
            color: .systemBlue,
            accessibilityDescription: "Blue Pen",
            action: #selector(AppDelegate.selectBluePen(_:))
        )
        let redPenButton = makeColorButton(
            color: .systemRed,
            accessibilityDescription: "Red Pen",
            action: #selector(AppDelegate.selectRedPen(_:))
        )
        let greenPenButton = makeColorButton(
            color: .systemGreen,
            accessibilityDescription: "Green Pen",
            action: #selector(AppDelegate.selectGreenPen(_:))
        )
        let eraserButton = makeToolbarButton(
            symbolName: "eraser",
            accessibilityDescription: "Eraser",
            action: #selector(AppDelegate.selectEraser(_:))
        )
        let textButton = makeToolbarButton(
            symbolName: "textformat",
            accessibilityDescription: "Text",
            action: #selector(AppDelegate.selectText(_:))
        )

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let penIndicator = NSTextField(labelWithString: "Primary Pen")
        penIndicator.font = .systemFont(ofSize: 13, weight: .medium)
        penIndicator.textColor = .secondaryLabelColor
        penIndicator.alignment = .left

        appControlsStack.addArrangedSubview(settingsButton)
        appControlsStack.addArrangedSubview(darkModeButton)
        drawingControlsStack.addArrangedSubview(undoButton)
        drawingControlsStack.addArrangedSubview(redoButton)
        drawingControlsStack.addArrangedSubview(clearButton)
        drawingControlsStack.addArrangedSubview(separator)
        drawingControlsStack.addArrangedSubview(blackPenButton)
        drawingControlsStack.addArrangedSubview(bluePenButton)
        drawingControlsStack.addArrangedSubview(redPenButton)
        drawingControlsStack.addArrangedSubview(greenPenButton)
        drawingControlsStack.addArrangedSubview(eraserButton)
        drawingControlsStack.addArrangedSubview(textButton)
        drawingControlsStack.addArrangedSubview(penIndicator)
        toolbar.addSubview(appControlsStack)
        toolbar.addSubview(drawingControlsStack)

        NSLayoutConstraint.activate([
            settingsButton.widthAnchor.constraint(equalToConstant: 32),
            settingsButton.heightAnchor.constraint(equalToConstant: 32),
            darkModeButton.widthAnchor.constraint(equalToConstant: 32),
            darkModeButton.heightAnchor.constraint(equalToConstant: 32),
            undoButton.widthAnchor.constraint(equalToConstant: 32),
            undoButton.heightAnchor.constraint(equalToConstant: 32),
            redoButton.widthAnchor.constraint(equalToConstant: 32),
            redoButton.heightAnchor.constraint(equalToConstant: 32),
            clearButton.widthAnchor.constraint(equalToConstant: 32),
            clearButton.heightAnchor.constraint(equalToConstant: 32),
            blackPenButton.widthAnchor.constraint(equalToConstant: 32),
            blackPenButton.heightAnchor.constraint(equalToConstant: 32),
            bluePenButton.widthAnchor.constraint(equalToConstant: 32),
            bluePenButton.heightAnchor.constraint(equalToConstant: 32),
            redPenButton.widthAnchor.constraint(equalToConstant: 32),
            redPenButton.heightAnchor.constraint(equalToConstant: 32),
            greenPenButton.widthAnchor.constraint(equalToConstant: 32),
            greenPenButton.heightAnchor.constraint(equalToConstant: 32),
            eraserButton.widthAnchor.constraint(equalToConstant: 32),
            eraserButton.heightAnchor.constraint(equalToConstant: 32),
            textButton.widthAnchor.constraint(equalToConstant: 32),
            textButton.heightAnchor.constraint(equalToConstant: 32),
            penIndicator.widthAnchor.constraint(equalToConstant: 92),
            separator.heightAnchor.constraint(equalToConstant: 22),
            appControlsStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
            appControlsStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            drawingControlsStack.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            drawingControlsStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            drawingControlsStack.leadingAnchor.constraint(greaterThanOrEqualTo: appControlsStack.trailingAnchor, constant: 16)
        ])

        self.settingsButton = settingsButton
        self.darkModeButton = darkModeButton
        self.undoButton = undoButton
        self.redoButton = redoButton
        self.clearButton = clearButton
        self.blackPenButton = blackPenButton
        self.bluePenButton = bluePenButton
        self.redPenButton = redPenButton
        self.greenPenButton = greenPenButton
        self.eraserButton = eraserButton
        self.textButton = textButton
        self.toolStatusLabel = penIndicator

        return toolbar
    }

    private func makeToolbarButton(
        symbolName: String,
        accessibilityDescription: String,
        action: Selector
    ) -> NSButton {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
        image?.isTemplate = true
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)

        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        button.toolTip = accessibilityDescription
        button.setAccessibilityLabel(accessibilityDescription)

        return button
    }

    private func makeColorButton(
        color: NSColor,
        accessibilityDescription: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(image: makeSwatchImage(color: color), target: self, action: action)

        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        button.toolTip = accessibilityDescription
        button.setAccessibilityLabel(accessibilityDescription)

        return button
    }

    private func makeSwatchImage(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))

        image.lockFocus()
        let rect = NSRect(x: 1, y: 1, width: 16, height: 16)
        let path = NSBezierPath(ovalIn: rect)

        color.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 1
        path.stroke()
        image.unlockFocus()

        return image
    }

    private func updateHistoryControls() {
        let canUndo = canvas?.canUndoStroke ?? false
        let canRedo = canvas?.canRedoStroke ?? false

        undoButton?.isEnabled = canUndo
        redoButton?.isEnabled = canRedo
        clearButton?.isEnabled = canvas?.canClear ?? false
        undoMenuItem?.isEnabled = canUndo
        redoMenuItem?.isEnabled = canRedo
    }

    private func updateThemeControls() {
        let isDarkMode = canvas?.isDarkMode ?? false
        let symbolName = isDarkMode ? "sun.max.fill" : "moon"
        let label = isDarkMode ? "Light Mode" : "Dark Mode"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)

        image?.isTemplate = true
        darkModeButton?.image = image
        darkModeButton?.state = isDarkMode ? .on : .off
        darkModeButton?.toolTip = label
        darkModeButton?.setAccessibilityLabel(label)
        darkModeButton?.contentTintColor = isDarkMode ? .controlAccentColor : .labelColor
        blackPenButton?.image = makeSwatchImage(color: canvas?.primaryPenColor ?? .black)
        scrollView?.backgroundColor = canvas?.canvasBackgroundColor ?? .white
    }

    private func updateToolControls() {
        let activeTool = canvas?.activeTool ?? .pen(.black)

        blackPenButton?.state = activeTool == .pen(.black) ? .on : .off
        bluePenButton?.state = activeTool == .pen(.blue) ? .on : .off
        redPenButton?.state = activeTool == .pen(.red) ? .on : .off
        greenPenButton?.state = activeTool == .pen(.green) ? .on : .off
        eraserButton?.state = activeTool == .eraser ? .on : .off
        eraserButton?.contentTintColor = activeTool == .eraser ? .controlAccentColor : .labelColor
        textButton?.state = activeTool == .text ? .on : .off
        textButton?.contentTintColor = activeTool == .text ? .controlAccentColor : .labelColor
        toolStatusLabel?.stringValue = activeTool.displayName
    }

    @MainActor
    private func configureMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let appName = ProcessInfo.processInfo.processName

        let aboutItem = appMenu.addItem(
            withTitle: "About \(appName)",
            action: #selector(AppDelegate.showAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(.separator())

        let settingsItem = appMenu.addItem(
            withTitle: "Settings...",
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(.separator())

        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let exportItem = fileMenu.addItem(
            withTitle: "Export as Image...",
            action: #selector(AppDelegate.exportCanvas(_:)),
            keyEquivalent: "s"
        )
        exportItem.target = self

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let zoomInItem = viewMenu.addItem(
            withTitle: "Zoom In",
            action: #selector(AppDelegate.zoomIn(_:)),
            keyEquivalent: "="
        )
        zoomInItem.target = self

        let zoomOutItem = viewMenu.addItem(
            withTitle: "Zoom Out",
            action: #selector(AppDelegate.zoomOut(_:)),
            keyEquivalent: "-"
        )
        zoomOutItem.target = self

        let actualSizeItem = viewMenu.addItem(
            withTitle: "Actual Size",
            action: #selector(AppDelegate.resetZoom(_:)),
            keyEquivalent: "0"
        )
        actualSizeItem.target = self

        viewMenu.addItem(.separator())

        let fullScreenItem = viewMenu.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(AppDelegate.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        fullScreenItem.target = self

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let undoMenuItem = editMenu.addItem(
            withTitle: "Undo",
            action: #selector(AppDelegate.undoStroke(_:)),
            keyEquivalent: "z"
        )
        undoMenuItem.target = self

        let redoItem = editMenu.addItem(
            withTitle: "Redo",
            action: #selector(AppDelegate.redoStroke(_:)),
            keyEquivalent: "Z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = self

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        self.undoMenuItem = undoMenuItem
        self.redoMenuItem = redoItem

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()

app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
