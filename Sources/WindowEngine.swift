import AppKit
import ApplicationServices
import CoreGraphics

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windowIDs: CFArray) -> CFArray?

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?

private typealias SLPSSetFrontProcessWithOptionsFunc = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
private typealias SLPSPostEventRecordToFunc = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeRawPointer) -> CGError

private let _slpsSetFrontProcessWithOptions: SLPSSetFrontProcessWithOptionsFunc? = {
    let sym = dlsym(dlopen(nil, RTLD_NOW), "_SLPSSetFrontProcessWithOptions")
        ?? dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW).flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") }
    guard let validSym = sym else { return nil }
    return unsafeBitCast(validSym, to: SLPSSetFrontProcessWithOptionsFunc.self)
}()

private let _slpsPostEventRecordTo: SLPSPostEventRecordToFunc? = {
    let sym = dlsym(dlopen(nil, RTLD_NOW), "SLPSPostEventRecordTo")
        ?? dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW).flatMap { dlsym($0, "SLPSPostEventRecordTo") }
    guard let validSym = sym else { return nil }
    return unsafeBitCast(validSym, to: SLPSPostEventRecordToFunc.self)
}()

private func axAttr<T>(_ el: AXUIElement, _ key: CFString) -> T? {
    var val: AnyObject?
    return AXUIElementCopyAttributeValue(el, key, &val) == .success ? (val as? T) : nil
}

private func axSize(_ el: AXUIElement) -> CGSize? {
    var val: AnyObject?
    guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &val) == .success,
          let v = val, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &size) ? size : nil
}

struct WindowItem: Equatable {
    let appName: String
    let subtitle: String?
    let appIcon: NSImage?
    let title: String
    let axWindow: AXUIElement?
    let cgWindowID: CGWindowID
    let app: NSRunningApplication
    let parentApp: NSRunningApplication?

    static func == (lhs: WindowItem, rhs: WindowItem) -> Bool {
        if lhs.cgWindowID != kCGNullWindowID && rhs.cgWindowID != kCGNullWindowID {
            return lhs.cgWindowID == rhs.cgWindowID
        }
        if let lAx = lhs.axWindow, let rAx = rhs.axWindow {
            return CFEqual(lAx, rAx)
        }
        return lhs.app.processIdentifier == rhs.app.processIdentifier && lhs.title == rhs.title
    }
}

final class WindowEngine {
    static let shared = WindowEngine()
    private var mruHistory: [WindowItem] = []

    private static let excludedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.Spotlight",
        "com.apple.screentimeui",
        "com.apple.TextInputMenuAgent",
        "com.apple.TextInputSwitcher"
    ]

    private static let knownBrowserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.kagi.kagimacOS",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Canary",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Beta",
        "org.mozilla.firefox",
        "org.mozilla.nightly",
        "org.mozilla.firefoxdeveloperedition",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "org.torproject.torbrowser",
        "org.chromium.Chromium",
        "org.mozilla.com.zen.browser",
        "com.duckduckgo.macos.browser"
    ]

    private func isBrowserApp(_ app: NSRunningApplication) -> Bool {
        guard let bid = app.bundleIdentifier?.lowercased() else { return false }
        if WindowEngine.knownBrowserBundleIDs.contains(where: { $0.caseInsensitiveCompare(bid) == .orderedSame }) {
            return true
        }
        return bid.contains("browser") || bid.contains("chrome") || bid.contains("firefox") || bid.contains("safari")
    }

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.recordActiveWindow()
        }
    }

    func recordActiveWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        let win: AXUIElement? = axAttr(appEl, kAXFocusedWindowAttribute as CFString) ?? axAttr(appEl, kAXMainWindowAttribute as CFString)
        var wid: CGWindowID = kCGNullWindowID
        if let w = win {
            var val: CGWindowID = 0
            if _AXUIElementGetWindow(w, &val) == .success && val > 0 { wid = val }
        }
        if let idx = mruHistory.firstIndex(where: {
            if wid != kCGNullWindowID && $0.cgWindowID != kCGNullWindowID {
                return $0.cgWindowID == wid
            }
            if let w = win, let itemAx = $0.axWindow {
                return CFEqual(itemAx, w)
            }
            return $0.app.processIdentifier == app.processIdentifier
        }) {
            mruHistory.insert(mruHistory.remove(at: idx), at: 0)
        }
    }

    func promoteToMRUFront(_ item: WindowItem) {
        mruHistory.removeAll { $0 == item }
        mruHistory.insert(item, at: 0)
    }

    func removeWindow(_ item: WindowItem) {
        mruHistory.removeAll { $0 == item }
    }

    func activateWindowServer(pid: pid_t, wid: CGWindowID) {
        guard wid != kCGNullWindowID else { return }
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == 0 else { return }

        // 0x200 (kCPSUserGenerated) | 0x1 (kSetFrontProcessFrontWindowOnly) = 0x201
        _ = _slpsSetFrontProcessWithOptions?(&psn, wid, 0x201)

        // Synthesize window key & active events to WindowServer to activate traffic lights & keyboard routing
        var eventBytes = [UInt8](repeating: 0, count: 0xf8)
        eventBytes[0x04] = 0xf8
        eventBytes[0x3a] = 0x10
        var windowID = wid
        withUnsafeBytes(of: &windowID) { rawWid in
            for (i, b) in rawWid.enumerated() {
                eventBytes[0x3c + i] = b
            }
        }
        for i in 0x20..<0x30 {
            eventBytes[i] = 0xff
        }

        // 0x01 = kCPSWindowFocusEvent
        eventBytes[0x08] = 0x01
        _ = _slpsPostEventRecordTo?(&psn, eventBytes)

        // 0x02 = kCPSWindowActiveEvent
        eventBytes[0x08] = 0x02
        _ = _slpsPostEventRecordTo?(&psn, eventBytes)
    }

    func findAXUIElements(pid: pid_t, targetWids: Set<CGWindowID>, maxScan: UInt64 = 800) -> [CGWindowID: AXUIElement] {
        guard !targetWids.isEmpty, let token = CFDataCreateMutable(kCFAllocatorDefault, 20) else { return [:] }
        CFDataSetLength(token, 20)
        guard let bytes = CFDataGetMutableBytePtr(token) else { return [:] }
        memset(bytes, 0, 20)
        var pidField = pid; memcpy(bytes, &pidField, 4)
        var magic = Int32(0x636f636f); memcpy(bytes + 8, &magic, 4)

        var remaining = targetWids
        var result: [CGWindowID: AXUIElement] = [:]

        for id in 0..<maxScan {
            var idField = id
            memcpy(bytes + 12, &idField, 8)
            if let unmanaged = _AXUIElementCreateWithRemoteToken(token) {
                let el = unmanaged.takeRetainedValue()
                var candidateWid: CGWindowID = 0
                if _AXUIElementGetWindow(el, &candidateWid) == .success && remaining.contains(candidateWid) {
                    var roleVal: AnyObject?
                    if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleVal) == .success,
                       let role = roleVal as? String, role == (kAXWindowRole as String) {
                        result[candidateWid] = el
                        remaining.remove(candidateWid)
                        if remaining.isEmpty { break }
                    }
                }
            }
        }
        return result
    }

    func windows() -> [WindowItem] {
        let cgList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let layer0 = cgList.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }

        let cgListAll = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let allLayer0 = cgListAll.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }

        var targetApps: [NSRunningApplication] = []
        var seenPids = Set<pid_t>()

        // 1. All regular applications
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier > 0 {
            if let bid = app.bundleIdentifier, WindowEngine.excludedBundleIDs.contains(bid) || bid == Bundle.main.bundleIdentifier { continue }
            if seenPids.insert(app.processIdentifier).inserted {
                targetApps.append(app)
            }
        }

        // 2. Any accessory/helper applications that own layer 0 windows across all spaces (e.g. Steam Helper, Teams Helper)
        for info in allLayer0 {
            if let pid = (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }), pid > 0, !seenPids.contains(pid) {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    if let bid = app.bundleIdentifier, WindowEngine.excludedBundleIDs.contains(bid) || bid == Bundle.main.bundleIdentifier { continue }
                    if let bid = app.bundleIdentifier, (bid.hasSuffix(".helper") || (app.localizedName?.hasSuffix(" Helper") == true)) {
                        seenPids.insert(pid)
                        targetApps.append(app)
                    }
                }
            }
        }

        var discovered: [WindowItem] = []
        var byWid: [CGWindowID: WindowItem] = [:]

        // Step 1: Discover windows on the current space via standard kAXWindows
        for app in targetApps {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            let axList: [AXUIElement] = axAttr(appEl, kAXWindowsAttribute as CFString) ?? []
            for axWin in axList {
                guard let item = makeWindowItem(for: axWin, wid: nil, app: app, layer0: layer0, allLayer0: allLayer0) else { continue }
                discovered.append(item)
                if item.cgWindowID != kCGNullWindowID { byWid[item.cgWindowID] = item }
            }
        }

        // Step 2: Cross-space discovery (virtual desktops & full-screen spaces)
        // Find layer 0 windows from allLayer0 not present in the current space AX list
        var missingByPid: [pid_t: (app: NSRunningApplication, wids: Set<CGWindowID>)] = [:]
        for info in allLayer0 {
            guard let pid = (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }),
                  let wid = (info[kCGWindowNumber as String] as? Int).map({ CGWindowID($0) }),
                  wid != kCGNullWindowID,
                  byWid[wid] == nil,
                  let app = targetApps.first(where: { $0.processIdentifier == pid }) else { continue }
            if app.isHidden { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.1 else { continue }
            if let b = info[kCGWindowBounds as String] as? [String: Any] {
                let w = b["Width"] as? Double ?? 0
                let h = b["Height"] as? Double ?? 0
                if w < 50 || h < 50 || h <= 40 { continue }
            }

            missingByPid[pid, default: (app: app, wids: [])].wids.insert(wid)
        }

        for (pid, tuple) in missingByPid {
            let foundAx = findAXUIElements(pid: pid, targetWids: tuple.wids)
            for wid in tuple.wids {
                guard let axWin = foundAx[wid] else { continue }
                guard let item = makeWindowItem(for: axWin, wid: wid, app: tuple.app, layer0: layer0, allLayer0: allLayer0) else { continue }
                discovered.append(item)
                byWid[wid] = item
            }
        }

        guard !discovered.isEmpty else { mruHistory.removeAll(); return [] }

        // Clean and update existing MRU history with fresh metadata
        var updated = mruHistory.compactMap { mru in discovered.first(where: { $0 == mru }) }

        // Identify current frontmost window and put at position 0 in MRU list
        if let frontApp = NSWorkspace.shared.frontmostApplication, frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            let appEl = AXUIElementCreateApplication(frontApp.processIdentifier)
            let win: AXUIElement? = axAttr(appEl, kAXFocusedWindowAttribute as CFString) ?? axAttr(appEl, kAXMainWindowAttribute as CFString)
            var frontWid: CGWindowID = kCGNullWindowID
            if let w = win {
                var val: CGWindowID = 0
                if _AXUIElementGetWindow(w, &val) == .success && val > 0 { frontWid = val }
            }
            let frontItem = discovered.first(where: {
                if frontWid != kCGNullWindowID && $0.cgWindowID != kCGNullWindowID {
                    return $0.cgWindowID == frontWid
                }
                if let w = win, let itemAx = $0.axWindow {
                    return CFEqual(itemAx, w)
                }
                return $0.app.processIdentifier == frontApp.processIdentifier || $0.parentApp?.processIdentifier == frontApp.processIdentifier
            })
            if let front = frontItem {
                updated.removeAll { $0 == front }
                updated.insert(front, at: 0)
            }
        }

        // Append any windows in layer 0 z-order that aren't yet in MRU history
        for info in layer0 {
            if let wid = (info[kCGWindowNumber as String] as? Int).map({ CGWindowID($0) }),
               let item = byWid[wid], !updated.contains(where: { $0 == item }) {
                updated.append(item)
            }
        }

        // Append any windows in allLayer0 z-order (other spaces / full-screen virtual desktops)
        for info in allLayer0 {
            if let wid = (info[kCGWindowNumber as String] as? Int).map({ CGWindowID($0) }),
               let item = byWid[wid], !updated.contains(where: { $0 == item }) {
                updated.append(item)
            }
        }

        // Append any remaining discovered windows (minimized or other spaces)
        for item in discovered where !updated.contains(where: { $0 == item }) { updated.append(item) }

        let consolidated = consolidateFullscreenWindows(updated, allLayer0: allLayer0)
        mruHistory = consolidated
        return consolidated
    }

    private func consolidateFullscreenWindows(_ items: [WindowItem], allLayer0: [[String: Any]]) -> [WindowItem] {
        let cid = CGSMainConnectionID()
        var fsSpaces = Set<Int>()
        if let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] {
            for d in displays {
                if let spaces = d["Spaces"] as? [[String: Any]] {
                    for s in spaces where (s["type"] as? Int) == 4 {
                        if let id = s["id64"] as? Int ?? s["id"] as? Int {
                            fsSpaces.insert(id)
                        }
                    }
                }
            }
        }

        func windowBounds(for wid: CGWindowID) -> CGRect? {
            guard wid != kCGNullWindowID,
                  let info = allLayer0.first(where: { ($0[kCGWindowNumber as String] as? Int).map(CGWindowID.init) == wid }),
                  let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double,
                  let y = b["Y"] as? Double,
                  let w = b["Width"] as? Double,
                  let h = b["Height"] as? Double else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }

        struct WinMeta {
            let item: WindowItem
            let isFS: Bool
            let subrole: String
        }

        var metas: [WinMeta] = []
        for item in items {
            let spaces = (CGSCopySpacesForWindows(cid, 0x7, [item.cgWindowID] as CFArray) as? [NSNumber])?.map { $0.intValue } ?? []
            let inFsSpace = spaces.contains(where: { fsSpaces.contains($0) })
            var axFS = false
            var subrole = ""
            if let ax = item.axWindow {
                var fsVal: AnyObject?
                if AXUIElementCopyAttributeValue(ax, "AXFullScreen" as CFString, &fsVal) == .success, let b = fsVal as? Bool {
                    axFS = b
                }
                var srVal: AnyObject?
                if AXUIElementCopyAttributeValue(ax, kAXSubroleAttribute as CFString, &srVal) == .success, let s = srVal as? String {
                    subrole = s
                }
            }
            metas.append(WinMeta(item: item, isFS: inFsSpace || axFS, subrole: subrole))
        }

        var result: [WindowItem] = []
        var removedWids = Set<CGWindowID>()

        for i in 0..<metas.count {
            let meta = metas[i]
            if removedWids.contains(meta.item.cgWindowID) { continue }

            let app = meta.item.app
            let isBrowser = isBrowserApp(app)

            if meta.isFS {
                // Fullscreen window: check if it's a browser video or dialog overlay pairing with a desktop tab window
                let isFsCandidate = isBrowser || meta.subrole == "AXDialog" || meta.item.title == meta.item.appName || meta.item.title.isEmpty
                if isFsCandidate {
                    let fsBounds = windowBounds(for: meta.item.cgWindowID)
                    var bestPartner: WinMeta? = nil

                    for j in 0..<metas.count where j != i {
                        let candidate = metas[j]
                        if removedWids.contains(candidate.item.cgWindowID) { continue }
                        guard candidate.item.app.processIdentifier == app.processIdentifier, !candidate.isFS else { continue }

                        if bestPartner == nil {
                            bestPartner = candidate
                        } else {
                            // Prefer matching title if FS title is meaningful
                            if !meta.item.title.isEmpty && meta.item.title != meta.item.appName && candidate.item.title == meta.item.title {
                                bestPartner = candidate
                                break
                            }
                            // Prefer matching bounds/size
                            if let fsB = fsBounds, let candB = windowBounds(for: candidate.item.cgWindowID) {
                                if abs(fsB.width - candB.width) < 20 && abs(fsB.height - candB.height) < 20 {
                                    bestPartner = candidate
                                }
                            }
                        }
                    }

                    if let partner = bestPartner {
                        let richTitle = (!partner.item.title.isEmpty && partner.item.title != partner.item.appName) ? partner.item.title : meta.item.title
                        let subtitle = partner.item.subtitle ?? meta.item.subtitle
                        let consolidated = WindowItem(
                            appName: meta.item.appName,
                            subtitle: subtitle,
                            appIcon: meta.item.appIcon ?? partner.item.appIcon,
                            title: richTitle,
                            axWindow: meta.item.axWindow ?? partner.item.axWindow,
                            cgWindowID: meta.item.cgWindowID,
                            app: meta.item.app,
                            parentApp: meta.item.parentApp ?? partner.item.parentApp
                        )
                        removedWids.insert(partner.item.cgWindowID)
                        result.append(consolidated)
                        continue
                    }
                }
            } else {
                // Non-fullscreen window: check if a subsequent FS window pairs with this desktop window
                if isBrowser {
                    let candBounds = windowBounds(for: meta.item.cgWindowID)
                    var bestPartner: WinMeta? = nil

                    for j in (i + 1)..<metas.count {
                        let candidate = metas[j]
                        if removedWids.contains(candidate.item.cgWindowID) { continue }
                        guard candidate.item.app.processIdentifier == app.processIdentifier, candidate.isFS else { continue }
                        let canMatch = isBrowser || candidate.subrole == "AXDialog" || candidate.item.title == candidate.item.appName || candidate.item.title.isEmpty
                        guard canMatch else { continue }

                        if bestPartner == nil {
                            bestPartner = candidate
                        } else {
                            if !candidate.item.title.isEmpty && candidate.item.title != candidate.item.appName && candidate.item.title == meta.item.title {
                                bestPartner = candidate
                                break
                            }
                            if let candB = candBounds, let fsB = windowBounds(for: candidate.item.cgWindowID) {
                                if abs(fsB.width - candB.width) < 20 && abs(fsB.height - candB.height) < 20 {
                                    bestPartner = candidate
                                }
                            }
                        }
                    }

                    if let partner = bestPartner {
                        let richTitle = (!meta.item.title.isEmpty && meta.item.title != meta.item.appName) ? meta.item.title : partner.item.title
                        let subtitle = meta.item.subtitle ?? partner.item.subtitle
                        let consolidated = WindowItem(
                            appName: meta.item.appName,
                            subtitle: subtitle,
                            appIcon: meta.item.appIcon ?? partner.item.appIcon,
                            title: richTitle,
                            axWindow: partner.item.axWindow ?? meta.item.axWindow,
                            cgWindowID: partner.item.cgWindowID,
                            app: meta.item.app,
                            parentApp: meta.item.parentApp ?? partner.item.parentApp
                        )
                        removedWids.insert(partner.item.cgWindowID)
                        result.append(consolidated)
                        continue
                    }
                }
            }

            result.append(meta.item)
        }

        return result
    }

    private func makeWindowItem(for axWindow: AXUIElement?, wid: CGWindowID? = nil, app: NSRunningApplication, layer0: [[String: Any]], allLayer0: [[String: Any]]) -> WindowItem? {
        if let axWin = axWindow {
            let role: String = axAttr(axWin, kAXRoleAttribute as CFString) ?? ""
            if !role.isEmpty && role != (kAXWindowRole as String) { return nil }

            let subrole: String = axAttr(axWin, kAXSubroleAttribute as CFString) ?? ""
            if subrole == "AXDesktopWindow" || subrole == "AXSystemDialog" { return nil }
        }

        let size: CGSize? = axWindow != nil ? axSize(axWindow!) : nil
        if let s = size, (s.width < 50 || s.height < 50) { return nil }

        var isMinimized = false
        if let axWin = axWindow {
            var minVal: AnyObject?
            isMinimized = (AXUIElementCopyAttributeValue(axWin, kAXMinimizedAttribute as CFString, &minVal) == .success) && ((minVal as? Bool) == true)
        }

        // Resolve CGWindowID
        var cgWid: CGWindowID = wid ?? kCGNullWindowID
        if cgWid == kCGNullWindowID, let axWin = axWindow {
            var w: CGWindowID = 0
            if _AXUIElementGetWindow(axWin, &w) == .success && w > 0 {
                cgWid = w
            } else {
                // Fallback: match by PID and bounds
                cgWid = matchingWindowID(for: app, size: size, layer0: layer0)
            }
        }

        // Determine if window is actively on-screen in current space
        let isOnScreen = (cgWid != kCGNullWindowID && layer0.contains(where: { ($0[kCGWindowNumber as String] as? Int).map(CGWindowID.init) == cgWid }))
            || (layer0.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) }))

        // Filter out closed / phantom / hidden windows
        if !isOnScreen && !isMinimized {
            if app.isHidden {
                return nil
            }
            // Check if there is a valid window on another space
            let hasSpaceWindow = allLayer0.contains { info in
                guard let pid = info[kCGWindowOwnerPID as String] as? Int, pid == Int(app.processIdentifier) else { return false }
                let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
                guard alpha > 0.1 else { return false }
                if let b = info[kCGWindowBounds as String] as? [String: Any] {
                    let w = b["Width"] as? Double ?? 0
                    let h = b["Height"] as? Double ?? 0
                    if w < 50 || h < 50 { return false }
                }
                if cgWid != kCGNullWindowID, let num = (info[kCGWindowNumber as String] as? Int).map(CGWindowID.init) {
                    return num == cgWid
                }
                return true
            }
            if !hasSpaceWindow {
                return nil
            }
        }

        var appName = app.localizedName ?? app.bundleURL?.lastPathComponent ?? "Application"
        var appIcon = app.icon
        var parentApp: NSRunningApplication? = nil

        // Resolve parent application for helper processes (e.g. Steam Helper -> Steam, Teams Helper -> Microsoft Teams)
        if let bundleId = app.bundleIdentifier, bundleId.hasSuffix(".helper") {
            let parentBundleId = String(bundleId.dropLast(".helper".count))
            if let pApp = NSRunningApplication.runningApplications(withBundleIdentifier: parentBundleId).first {
                parentApp = pApp
                if let pName = pApp.localizedName, !pName.isEmpty { appName = pName }
                if let pIcon = pApp.icon { appIcon = pIcon }
            }
        }
        if appName.hasSuffix(" Helper") {
            let clean = String(appName.dropLast(" Helper".count))
            if let pApp = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == clean }) {
                parentApp = pApp
                appName = pApp.localizedName ?? clean
                appIcon = pApp.icon ?? appIcon
            } else {
                appName = clean
            }
        }

        var title = ""
        if let axWin = axWindow {
            title = (axAttr(axWin, kAXTitleAttribute as CFString) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                let subrole: String = axAttr(axWin, kAXSubroleAttribute as CFString) ?? ""
                if subrole == "AXUnknown" { return nil }
                let doc: String = axAttr(axWin, kAXDocumentAttribute as CFString) ?? ""
                let desc: String = axAttr(axWin, kAXDescriptionAttribute as CFString) ?? ""
                title = !doc.isEmpty ? URL(fileURLWithPath: doc).lastPathComponent : (!desc.isEmpty ? desc : appName)
            }
        }

        // If title is still empty, check CGWindowName from allLayer0
        if title.isEmpty, cgWid != kCGNullWindowID {
            if let info = allLayer0.first(where: { ($0[kCGWindowNumber as String] as? Int).map(CGWindowID.init) == cgWid }),
               let cgName = info[kCGWindowName as String] as? String, !cgName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = cgName.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if title.isEmpty {
            title = appName
        }

        // Strict Finder rule: Finder must be completely excluded unless at least one standard file/directory window is open
        if app.bundleIdentifier == "com.apple.finder" && (title == "Desktop" || title == "Desktop 1") {
            return nil
        }

        let (cleanTitle, subtitle) = parseTitleAndSubtitle(title, appName: appName)

        return WindowItem(appName: appName, subtitle: subtitle, appIcon: appIcon, title: cleanTitle, axWindow: axWindow, cgWindowID: cgWid, app: app, parentApp: parentApp)
    }

    private static let profileRegex = try? NSRegularExpression(pattern: #"^(Personal|Work|School|Default|Profile \d+|Guest)\s*[—–-]\s*"#, options: .caseInsensitive)

    private func parseTitleAndSubtitle(_ raw: String, appName: String) -> (String, String?) {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var subtitle: String? = nil

        // 1. Check for Safari / Browser Profile prefixes (e.g. "Personal — Page Title" or "Work — Page Title")
        if let regex = WindowEngine.profileRegex,
           let match = regex.firstMatch(in: title, range: NSRange(location: 0, length: title.utf16.count)),
           let range = Range(match.range, in: title) {
            subtitle = String(title[range]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "—–-")))
            title = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Strip redundant trailing app name suffix (e.g. " — Safari", " - Google Chrome", " — Visual Studio Code")
        let suffixes = [" — \(appName)", " - \(appName)", " — Safari", " - Safari", " — Google Chrome", " - Google Chrome", " — Brave", " - Brave", " — Arc", " - Arc", " — Firefox", " - Firefox", " — Visual Studio Code", " - Visual Studio Code", " — Antigravity IDE", " - Antigravity IDE", " — Cursor", " - Cursor", " — Xcode", " - Xcode"]
        for s in suffixes where title.hasSuffix(s) {
            title = String(title.dropLast(s.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. For IDEs & Editors, if title has "Project — File" or "File — Project", extract project into subtitle if no profile was found
        if subtitle == nil {
            let parts = title.components(separatedBy: " — ")
            if parts.count == 2 {
                let p0 = parts[0].trimmingCharacters(in: .whitespaces), p1 = parts[1].trimmingCharacters(in: .whitespaces)
                if p0.contains(".") && !p1.contains(".") { title = p0; subtitle = p1 }
                else if !p0.contains(".") && p1.contains(".") { title = p1; subtitle = p0 }
            }
        }
        return (title.isEmpty ? appName : title, subtitle)
    }

    private func matchingWindowID(for app: NSRunningApplication, size: CGSize?, layer0: [[String: Any]]) -> CGWindowID {
        let wins = layer0.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) }
        if wins.count == 1, let wid = wins[0][kCGWindowNumber as String] as? Int { return CGWindowID(wid) }
        if let s = size, let best = wins.min(by: { a, b in
            let bA = a[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let bB = b[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let dA = abs((bA["Width"] as? Double ?? 0) - Double(s.width)) + abs((bA["Height"] as? Double ?? 0) - Double(s.height))
            let dB = abs((bB["Width"] as? Double ?? 0) - Double(s.width)) + abs((bB["Height"] as? Double ?? 0) - Double(s.height))
            return dA < dB
        }), let wid = best[kCGWindowNumber as String] as? Int {
            return CGWindowID(wid)
        }
        return (wins.first?[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } ?? kCGNullWindowID
    }
}
