import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

private func makeLabel(size: CGFloat, weight: NSFont.Weight, color: NSColor, lines: Int = 1) -> NSTextField {
    let lbl = NSTextField(labelWithString: "")
    lbl.font = .systemFont(ofSize: size, weight: weight)
    lbl.textColor = color
    lbl.alignment = .center
    lbl.maximumNumberOfLines = lines
    lbl.lineBreakMode = .byTruncatingTail
    return lbl
}

private final class SwitcherCardView: NSView {
    let index: Int
    var isCardSelected: Bool = false {
        didSet {
            guard oldValue != isCardSelected else { return }
            updateSelectionState()
        }
    }
    var onClick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?

    private let iconImageView = NSImageView()
    private let appLabel = makeLabel(size: 11, weight: .semibold, color: NSColor(white: 0.75, alpha: 1.0))
    private let titleLabel = makeLabel(size: 12, weight: .bold, color: .white, lines: 3)
    private var trackingArea: NSTrackingArea?

    init(index: Int, window: WindowItem, frame: NSRect) {
        self.index = index
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        // Large Crisp App Icon
        let iconSize: CGFloat = 58
        let iconX = (frame.width - iconSize) / 2
        iconImageView.frame = NSRect(x: iconX, y: frame.height - iconSize - 12, width: iconSize, height: iconSize)
        iconImageView.image = window.appIcon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: window.appName)
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconImageView)

        // App Name + Subtitle Badge (e.g. "Safari • Personal" or "Antigravity IDE • TrackpadGestures")
        appLabel.stringValue = window.subtitle.map { "\(window.appName) • \($0)" } ?? window.appName
        appLabel.frame = NSRect(x: 8, y: 44, width: frame.width - 16, height: 16)
        addSubview(appLabel)

        // Rich Window Title Label (Supports up to 3 lines of clear, full-length text)
        titleLabel.stringValue = window.title
        titleLabel.frame = NSRect(x: 8, y: 6, width: frame.width - 16, height: 36)
        addSubview(titleLabel)

        updateSelectionState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(index) }
    override func mouseMoved(with event: NSEvent) { onHover?(index) }
    override func mouseDown(with event: NSEvent) { onClick?(index) }

    private func updateSelectionState() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        layer?.borderColor = isCardSelected ? NSColor.controlAccentColor.cgColor : NSColor(white: 1.0, alpha: 0.12).cgColor
        layer?.borderWidth = isCardSelected ? 3.0 : 1.0
        layer?.backgroundColor = isCardSelected ? NSColor(white: 0.35, alpha: 0.7).cgColor : NSColor(white: 0.12, alpha: 0.5).cgColor
        titleLabel.textColor = isCardSelected ? .white : NSColor(white: 0.88, alpha: 1.0)
        appLabel.textColor = isCardSelected ? NSColor(white: 0.95, alpha: 1.0) : NSColor(white: 0.6, alpha: 1.0)
        CATransaction.commit()
    }
}

final class SwitcherPanel: NSPanel {
    static let shared = SwitcherPanel()

    private(set) var windows: [WindowItem] = []
    private(set) var selectedIndex = 0
    private(set) var gridColumns = 1
    private(set) var gridRows = 1
    private var cardViews: [SwitcherCardView] = []

    private var initialMousePos: NSPoint = .zero
    private var lastHandledMousePos: NSPoint = .zero
    private var mouseActivated: Bool = false

    private let visualEffectView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let cardsContainer = NSView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 20
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.15).cgColor
        visualEffectView.layer?.borderWidth = 1.0

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = cardsContainer

        visualEffectView.addSubview(scrollView)
        contentView = visualEffectView
    }

    var selectedItem: WindowItem? {
        windows.indices.contains(selectedIndex) ? windows[selectedIndex] : nil
    }

    @discardableResult
    func show(initialDirection: Int = 1) -> Bool {
        let wins = WindowEngine.shared.windows()
        guard !wins.isEmpty else { return false }
        windows = wins
        selectedIndex = initialDirection > 0 ? (wins.count > 1 ? 1 : 0) : max(0, wins.count - 1)
        initialMousePos = NSEvent.mouseLocation
        lastHandledMousePos = initialMousePos
        mouseActivated = false
        render()
        orderFrontRegardless()
        return true
    }

    func step(direction: Int) {
        if !isVisible {
            show(initialDirection: direction)
            return
        }
        guard !windows.isEmpty else { return }
        selectedIndex = (selectedIndex + (direction > 0 ? 1 : windows.count - 1)) % windows.count
        lastHandledMousePos = NSEvent.mouseLocation
        updateHighlightsAndScroll()
    }

    func stepGrid(rowDelta: Int, colDelta: Int, allowWrap: Bool = false) {
        if !isVisible {
            step(direction: colDelta >= 0 ? 1 : -1)
            return
        }
        guard !windows.isEmpty else { return }
        lastHandledMousePos = NSEvent.mouseLocation
        if gridRows <= 1 {
            let delta = colDelta + rowDelta
            selectedIndex = allowWrap ? (selectedIndex + delta % windows.count + windows.count) % windows.count : max(0, min(windows.count - 1, selectedIndex + delta))
        } else {
            var r = selectedIndex / gridColumns
            var c = selectedIndex % gridColumns
            // Vertical navigation
            if rowDelta != 0 {
                r = allowWrap ? (r + rowDelta + gridRows) % gridRows : max(0, min(gridRows - 1, r + rowDelta))
            }
            let countInRow = min(gridColumns, windows.count - r * gridColumns)
            // Horizontal navigation
            if colDelta != 0 {
                c = allowWrap ? (c + colDelta + countInRow) % countInRow : max(0, min(countInRow - 1, c + colDelta))
            } else {
                c = min(c, countInRow - 1)
            }
            selectedIndex = max(0, min(windows.count - 1, r * gridColumns + c))
        }
        updateHighlightsAndScroll()
    }

    func selectGrid(row: Int, col: Int) {
        guard !windows.isEmpty else { return }
        let r = max(0, min(row, gridRows - 1))
        let countInRow = min(gridColumns, windows.count - r * gridColumns)
        let c = max(0, min(col, max(0, countInRow - 1)))
        select(index: min(r * gridColumns + c, windows.count - 1))
    }

    func select(index: Int) {
        guard windows.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        lastHandledMousePos = NSEvent.mouseLocation
        updateHighlightsAndScroll()
    }

    func handleCardHover(index: Int) {
        guard isVisible, windows.indices.contains(index) else { return }
        let currentPos = NSEvent.mouseLocation
        if !mouseActivated {
            let dx = currentPos.x - initialMousePos.x
            let dy = currentPos.y - initialMousePos.y
            if hypot(dx, dy) < 5.0 {
                return
            }
            mouseActivated = true
        } else {
            let dx = currentPos.x - lastHandledMousePos.x
            let dy = currentPos.y - lastHandledMousePos.y
            if hypot(dx, dy) < 2.0 {
                return
            }
        }
        lastHandledMousePos = currentPos
        if selectedIndex != index {
            selectedIndex = index
            updateHighlightsAndScroll(scroll: false)
        }
    }

    func closeSelectedWindow() {
        guard let item = selectedItem else { return }
        WindowEngine.shared.removeWindow(item)
        closeWindow(item)
        removeCurrent(where: { $0 == item })
    }

    func quitSelectedApp() {
        guard let item = selectedItem else { return }
        item.app.terminate()
        item.parentApp?.terminate()
        removeCurrent(where: { $0.app.processIdentifier == item.app.processIdentifier || ($0.parentApp != nil && $0.parentApp?.processIdentifier == item.parentApp?.processIdentifier) })
    }

    private func removeCurrent(where predicate: (WindowItem) -> Bool) {
        windows.removeAll(where: predicate)
        if windows.isEmpty {
            dismiss()
        } else {
            selectedIndex = min(selectedIndex, windows.count - 1)
            render()
        }
    }

    func commit() {
        GestureEngine.shared.resetSessionState()
        guard let item = selectedItem else { dismiss(); return }
        dismiss()
        activateWindow(item)
    }

    func dismiss() {
        GestureEngine.shared.resetSessionState()
        orderOut(nil)
        cardViews.removeAll()
        cardsContainer.subviews.forEach { $0.removeFromSuperview() }
        windows.removeAll()
        mouseActivated = false
        initialMousePos = .zero
        lastHandledMousePos = .zero
    }

    private func render() {
        buildCards()
        updateLayout()
        updateHighlightsAndScroll()
    }

    private func buildCards() {
        cardViews.removeAll()
        cardsContainer.subviews.forEach { $0.removeFromSuperview() }

        let cardW: CGFloat = 190, cardH: CGFloat = 155, spacing: CGFloat = 14, margin: CGFloat = 16
        let n = windows.count
        gridColumns = n <= 4 ? n : min(5, Int(ceil(Double(n) / 2.0)))
        gridRows = Int(ceil(Double(n) / Double(gridColumns)))

        let maxCols = min(gridColumns, n)
        let totalW = margin * 2 + CGFloat(maxCols) * cardW + CGFloat(max(0, maxCols - 1)) * spacing
        let totalH = margin * 2 + CGFloat(gridRows) * cardH + CGFloat(max(0, gridRows - 1)) * spacing

        for r in 0..<gridRows {
            let start = r * gridColumns, count = min(gridColumns, n - start)
            let rowW = CGFloat(count) * cardW + CGFloat(max(0, count - 1)) * spacing
            let rowX = (totalW - margin * 2 - rowW) / 2

            for c in 0..<count {
                let idx = start + c
                let x = margin + rowX + CGFloat(c) * (cardW + spacing)
                let y = margin + CGFloat(gridRows - 1 - r) * (cardH + spacing)
                let card = SwitcherCardView(index: idx, window: windows[idx], frame: NSRect(x: x, y: y, width: cardW, height: cardH))
                card.onClick = { [weak self] i in self?.selectedIndex = i; self?.commit() }
                card.onHover = { [weak self] i in self?.handleCardHover(index: i) }
                cardsContainer.addSubview(card)
                cardViews.append(card)
            }
        }
        cardsContainer.frame = NSRect(x: 0, y: 0, width: totalW, height: totalH)
    }

    private func updateLayout() {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? NSScreen()
        let visible = screen.visibleFrame
        let w = min(cardsContainer.frame.width, visible.width - 60)
        let h = min(cardsContainer.frame.height, visible.height - 60)
        visualEffectView.frame = NSRect(x: 0, y: 0, width: w, height: h)
        scrollView.frame = visualEffectView.bounds
        setFrame(NSRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h), display: true)
    }

    private func updateHighlightsAndScroll(scroll: Bool = true) {
        for (i, card) in cardViews.enumerated() { card.isCardSelected = (i == selectedIndex) }
        if scroll && cardViews.indices.contains(selectedIndex) {
            cardsContainer.scrollToVisible(cardViews[selectedIndex].frame.insetBy(dx: -16, dy: -16))
        }
    }

    private func closeWindow(_ item: WindowItem) {
        guard let win = item.axWindow else { return }
        var btn: AnyObject?
        // 1. Try standard close button
        if AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &btn) == .success, let b = btn {
            AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
            return
        }
        // 2. Try perform close / cancel action directly on window
        if AXUIElementPerformAction(win, "AXClose" as CFString) != .success {
            AXUIElementPerformAction(win, "AXCancel" as CFString)
        }
    }

    private func activateWindow(_ item: WindowItem) {
        WindowEngine.shared.promoteToMRUFront(item)
        let app = item.app

        // 1. Unhide application if hidden (Cmd+H)
        if app.isHidden {
            app.unhide()
        }

        // 2. Unminimize window if minimized
        if let win = item.axWindow {
            var minVal: AnyObject?
            if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minVal) == .success, (minVal as? Bool) == true {
                AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(win, "AXPress" as CFString)
            }
        }

        // 3. Switch spaces & make key window via WindowServer
        WindowEngine.shared.activateWindowServer(pid: app.processIdentifier, wid: item.cgWindowID)

        // 4. Force activate application
        forceActivateApp(app)

        // 5. Accessibility frontmost, main, and raise
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        var targetAx = item.axWindow
        if targetAx == nil && item.cgWindowID != kCGNullWindowID {
            var axWinsVal: AnyObject?
            if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &axWinsVal) == .success,
               let axWins = axWinsVal as? [AXUIElement] {
                for candidate in axWins {
                    var cWid: CGWindowID = 0
                    if _AXUIElementGetWindow(candidate, &cWid) == .success && cWid == item.cgWindowID {
                        targetAx = candidate
                        break
                    }
                }
            }
            if targetAx == nil {
                let found = WindowEngine.shared.findAXUIElements(pid: app.processIdentifier, targetWids: [item.cgWindowID])
                targetAx = found[item.cgWindowID]
            }
        }

        if let win = targetAx {
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        }

        // 6. Handle parent app if applicable (helper processes)
        if let parentApp = item.parentApp {
            if parentApp.isHidden { parentApp.unhide() }
            WindowEngine.shared.activateWindowServer(pid: parentApp.processIdentifier, wid: item.cgWindowID)
            forceActivateApp(parentApp)
            let parentEl = AXUIElementCreateApplication(parentApp.processIdentifier)
            AXUIElementSetAttributeValue(parentEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }

        // 7. Multi-frame focus reinforcement for cross-space transitions
        // When macOS transitions between spaces or enters/exits fullscreen, the target window
        // must be re-raised and confirmed key as the space animation lands.
        let targetWid = item.cgWindowID
        let targetPid = app.processIdentifier
        let finalAx = targetAx
        for delay in [0.06, 0.16, 0.28] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                WindowEngine.shared.activateWindowServer(pid: targetPid, wid: targetWid)
                self?.forceActivateApp(app)
                if let win = finalAx {
                    AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                }
            }
        }
    }

    private func forceActivateApp(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
