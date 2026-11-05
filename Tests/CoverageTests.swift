import AppKit
import ApplicationServices
import Carbon
import SQLite3
import SwiftUI
import XCTest
@testable import ClipboardAssistant

@MainActor
final class CoverageTests: XCTestCase {
    private var directories: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        for suite in suites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        directories = []
        suites = []
        super.tearDown()
    }

    func testLaunchAssemblesATemporaryStackAndStopsTheMonitor() throws {
        let (settings, suite) = makeSettings()
        let directory = try makeDirectory()
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let model = try delegate.launch(directory: directory, settings: settings, hotkeys: FakeGlobalHotkeys())
        model.monitor.stop()
        XCTAssertEqual(model.store.directory, directory)
        _ = suite
    }

    func testCaptureMonitorCoversSkipAndCaptureBranches() throws {
        let (settings, _) = makeSettings()
        let board = namedPasteboard()
        let monitor = CaptureMonitor(pasteboard: board)
        monitor.frontmost = { ("com.example.editor", "Editor") }
        monitor.secureInputEnabled = { false }
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        monitor.clock = { fixed }

        monitor.start(settings: settings)
        let timer = expectation(description: "timer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { timer.fulfill() }
        wait(for: [timer], timeout: 2)
        monitor.stop()
        monitor.start(settings: settings)
        monitor.stop()

        finish(monitor)
        settings.manuallyPaused = true
        board.setString("paused", forType: .string)
        finish(monitor)
        settings.manuallyPaused = false

        monitor.frontmost = { (Bundle.main.bundleIdentifier, "Self") }
        board.setString("self", forType: .string)
        finish(monitor)
        monitor.frontmost = { ("com.example.editor", "Editor") }

        monitor.secureInputEnabled = { true }
        board.setString("secure", forType: .string)
        finish(monitor)
        monitor.secureInputEnabled = { false }
        board.setString("sticky", forType: .string)
        finish(monitor)
        settings.recordDuringSecureInput = true
        monitor.secureInputEnabled = { true }
        board.setString("record", forType: .string)
        finish(monitor)
        settings.recordDuringSecureInput = false
        monitor.secureInputEnabled = { false }
        let afterSecure = fixed.addingTimeInterval(2)
        monitor.clock = { afterSecure }

        set(board, values: [PasteboardUTI.transient: Data()])
        finish(monitor)
        set(board, values: [PasteboardUTI.concealed: Data(), PasteboardUTI.plain: Data("secret".utf8)])
        finish(monitor)
        settings.ignoreConcealed = false
        settings.excludedApps = [ExcludedApp(bundleID: "com.example.editor", name: "Editor")]
        set(board, values: [PasteboardUTI.plain: Data("excluded".utf8)])
        finish(monitor)
        settings.excludedApps = []
        monitor.frontmost = { (nil, "Unknown") }
        set(board, values: [PasteboardUTI.concealed: Data()])
        finish(monitor)
        monitor.frontmost = { ("com.example.editor", "Editor") }
        settings.ignoreConcealed = true

        board.clearContents()
        finish(monitor)

        var captured: [String] = []
        monitor.onCaptured = { item, bundle, name in
            captured.append("\(item.plainText)|\(bundle ?? "")|\(name)")
        }
        set(board, values: [
            PasteboardUTI.plain: Data("hello".utf8),
            PasteboardUTI.remote: Data()
        ])
        finish(monitor)
        XCTAssertEqual(captured, ["hello|com.example.editor|\(L10n.text("通用剪贴板", "Universal Clipboard"))"])

        let echo = "echo-me"
        set(board, values: [PasteboardUTI.plain: Data(echo.utf8)])
        let token = monitor.beginSelfWrite(hash: ContentHash.text(echo), digests: [ContentHash.text(echo)])
        monitor.finishSelfWrite(token: token, changeCount: board.changeCount, now: afterSecure)
        finish(monitor)
        monitor.finishSelfWrite(token: 999, changeCount: board.changeCount, now: afterSecure)
        XCTAssertTrue(captured.count >= 1)
    }

    func testPasteboardReaderKeepsMarkersAndTruncatesOversize() {
        let board = namedPasteboard()
        let big = Data(repeating: 65, count: 32)
        let image = Data(repeating: 9, count: 32)
        set(board, values: [
            PasteboardUTI.plain: big,
            PasteboardUTI.png: image,
            PasteboardUTI.fileURL: Data("/tmp/a".utf8),
            PasteboardUTI.concealed: Data(),
            "com.example.unknown": Data("skip".utf8)
        ])
        let limits = CaptureLimits(maxTextBytes: 4, maxImageBytes: 4, previewBytes: 2)
        let snapshot = PasteboardReader.snapshot(board, limits: limits)
        XCTAssertTrue(snapshot.hasConcealedMarker)
        XCTAssertFalse(snapshot.hasTransientMarker)
        XCTAssertFalse(snapshot.hasRemoteMarker)
        XCTAssertEqual(snapshot.items.first?.fullByteCounts[PasteboardUTI.plain], 32)
        XCTAssertEqual(snapshot.items.first?.values[PasteboardUTI.plain], Data(big.prefix(2)))
        XCTAssertNil(snapshot.items.first?.values[PasteboardUTI.png])
        let remote = PasteboardSnapshot(items: [PasteboardItemData(values: [PasteboardUTI.remote: Data()])])
        XCTAssertTrue(remote.hasRemoteMarker)
        let transient = PasteboardSnapshot(items: [PasteboardItemData(values: [PasteboardUTI.transient: Data()])])
        XCTAssertTrue(transient.hasTransientMarker)
    }

    func testPasteboardWriterCoversPlainFileAndFallback() throws {
        let board = namedPasteboard()
        let directory = try makeDirectory()
        let file = directory.appendingPathComponent("note.txt")
        try Data("file-body".utf8).write(to: file)
        let text = makeItem(kind: .text, text: "alpha")
        XCTAssertEqual(PasteboardWriter.write(item: text, representations: [], directory: directory, mode: .plainText, pasteboard: board), board.changeCount)
        XCTAssertEqual(board.string(forType: .string), "alpha")

        let oversize = makeItem(kind: .text, text: "big", oversize: true)
        let before = board.changeCount
        XCTAssertEqual(PasteboardWriter.write(item: oversize, representations: [], directory: directory, mode: .automatic, pasteboard: board), before)

        let paths = file.path + "\n/tmp/missing-coverage-file"
        let fileItem = makeItem(kind: .file, text: "note.txt")
        let fileReps = [StoredRepresentation(uti: PasteboardUTI.fileURL, storage: "inline", relativePath: nil, inlineValue: paths)]
        _ = PasteboardWriter.write(item: fileItem, representations: fileReps, directory: directory, mode: .automatic, pasteboard: board)
        _ = PasteboardWriter.write(item: fileItem, representations: fileReps, directory: directory, mode: .plainCopy, pasteboard: board)

        let stored = directory.appendingPathComponent("payload")
        try Data("stored".utf8).write(to: stored)
        let rich = makeItem(kind: .rich, text: "rich")
        let reps = [
            StoredRepresentation(uti: PasteboardUTI.rtf, storage: "file", relativePath: "payload", inlineValue: nil),
            StoredRepresentation(uti: PasteboardUTI.url, storage: "inline", relativePath: nil, inlineValue: "https://example.com"),
            StoredRepresentation(uti: PasteboardUTI.plain, storage: "file", relativePath: "missing", inlineValue: nil),
            StoredRepresentation(uti: PasteboardUTI.fileURL, storage: "inline", relativePath: nil, inlineValue: file.path)
        ]
        _ = PasteboardWriter.write(item: rich, representations: reps, directory: directory, mode: .automatic, pasteboard: board)
        _ = PasteboardWriter.write(item: rich, representations: [], directory: directory, mode: .copyOnly, pasteboard: board)
        for mode in [PasteMode.automatic, .copyOnly, .plainText, .plainCopy] {
            _ = mode.logName
        }
    }

    func testPasteServiceReportsOversizeCopyAndManualPaste() throws {
        let (model, _, _) = try makeModel()
        let board = model.pasteService.pasteboard
        let directory = model.store.directory
        var prepared = 0
        var outcomes: [PasteOutcome] = []
        let service = model.pasteService
        let oversize = makeItem(kind: .text, text: "too-big", oversize: true)
        service.perform(
            item: oversize,
            representations: [],
            directory: directory,
            mode: .automatic,
            targetBundleID: nil,
            behavior: .automatic,
            beginSelfWrite: { _, _ in 1 },
            finishSelfWrite: { _, _ in },
            completion: { outcomes.append($0) }
        )
        let plain = makeItem(kind: .text, text: "copied")
        service.perform(
            item: plain,
            representations: [],
            directory: directory,
            mode: .copyOnly,
            targetBundleID: "com.apple.finder",
            behavior: .automatic,
            beginSelfWrite: { _, _ in 2 },
            finishSelfWrite: { _, _ in },
            completion: { outcomes.append($0) }
        )
        let query = AccessibilityClient.queryTrusted
        let post = KeystrokeSender.postEvent
        defer {
            AccessibilityClient.queryTrusted = query
            KeystrokeSender.postEvent = post
        }
        AccessibilityClient.queryTrusted = { _ in false }
        service.perform(
            item: plain,
            representations: [],
            directory: directory,
            mode: .automatic,
            targetBundleID: "com.apple.finder",
            behavior: .automatic,
            beginSelfWrite: { _, _ in 3 },
            finishSelfWrite: { _, _ in },
            completion: { outcomes.append($0) }
        )
        AccessibilityClient.queryTrusted = { _ in true }
        KeystrokeSender.postEvent = { _ in }
        let sent = expectation(description: "keystroke")
        service.perform(
            item: plain,
            representations: [],
            directory: directory,
            mode: .plainText,
            targetBundleID: "com.apple.finder",
            behavior: .automatic,
            beginSelfWrite: { _, _ in 4 },
            finishSelfWrite: { _, _ in },
            prepareForKeystroke: { prepared += 1 },
            completion: { outcome in
                outcomes.append(outcome)
                sent.fulfill()
            }
        )
        wait(for: [sent], timeout: 2)
        XCTAssertEqual(prepared, 1)
        XCTAssertEqual(outcomes.count, 4)
        XCTAssertFalse(outcomes[0].wroteClipboard)
        XCTAssertTrue(outcomes[1].wroteClipboard)
        XCTAssertFalse(outcomes[1].sentKeystroke)
        XCTAssertNotNil(outcomes[2].message)
        XCTAssertTrue(outcomes[3].sentKeystroke)
        _ = board
        AccessibilityClient.queryTrusted = { _ in false }
        XCTAssertFalse(KeystrokeSender.sendCommandV())
    }

    func testModelPastePinUndoRevealAndRetention() throws {
        let (model, directory, _) = try makeModel()
        model.paste(mode: .automatic, itemID: "missing")
        let inserted = try insert("first", model: model)
        try insert("second", model: model)
        model.reload()
        model.rememberFrontApp()
        model.paste(mode: .copyOnly)
        flush()
        model.paste(mode: .plainText)
        flush()
        model.togglePin(id: nil)
        model.togglePin(id: "missing")
        model.togglePin(id: inserted.id)
        model.reload()
        XCTAssertTrue(model.items.first { $0.id == inserted.id }?.pinned == true)
        model.togglePin(id: inserted.id)
        model.setPinnedDeletePresented(true)
        model.setPinnedDeletePresented(true)
        model.setPinnedDeletePresented(false)
        model.deleteSelected()
        model.undoDelete()
        model.undoDelete()
        model.revealInFinder(id: nil)
        model.revealInFinder(id: "missing")
        let file = directory.appendingPathComponent("shown.txt")
        try Data("shown".utf8).write(to: file)
        let captured = CapturedClipboard(
            kind: .file,
            plainText: "shown.txt",
            contentHash: "file-hash-coverage",
            byteSize: 5,
            imageWidth: nil,
            imageHeight: nil,
            oversize: false,
            representations: [CapturedRepresentation(uti: PasteboardUTI.fileURL, data: nil, inlineValue: file.path + "\n/tmp/missing-coverage")]
        )
        let stored = try model.store.insertOrTouch(captured, sourceBundleID: "com.example", sourceName: "Example")
        model.reload()
        model.revealInFinder(id: stored.id)
        XCTAssertNil(model.thumbnailURL(for: stored.id))
        let image = try imageData()
        if let relative = try PayloadStore(root: directory).writeThumbnail(itemID: stored.id, imageData: image) {
            XCTAssertNotNil(model.thumbnailURL(for: stored.id))
            _ = relative
        }
        _ = try PayloadStore(root: directory).fileURL(relativePath: "thumbs/\(stored.id).jpg")
        _ = try PayloadStore(root: directory).write(itemID: stored.id, uti: PasteboardUTI.plain, data: Data("x".utf8))

        let oversize = CapturedClipboard(
            kind: .text,
            plainText: "big",
            contentHash: "oversize-coverage",
            byteSize: 9,
            imageWidth: nil,
            imageHeight: nil,
            oversize: true,
            representations: []
        )
        let huge = try model.store.insertOrTouch(oversize, sourceBundleID: nil, sourceName: "Example")
        model.reload()
        model.paste(mode: .automatic, itemID: huge.id)
        flush()

        try model.store.applyRetention(RetentionPolicy(maxCount: 1, maxAge: 1, maxImageBytes: 1), now: Date().addingTimeInterval(10_000))
        model.start()
        model.monitor.stop()
        try executeSQL("DROP TABLE items", at: directory)
        model.monitor.pasteboard = namedPasteboard()
        model.monitor.pasteboard.setString("after-drop", forType: .string)
        model.monitor.frontmost = { ("com.example.editor", "Editor") }
        model.monitor.secureInputEnabled = { false }
        finish(model.monitor)
    }

    func testPanelHandlesKeysPlacementsAndSearchEditingKeys() throws {
        let (model, _, _) = try makeModel()
        _ = try insert("one", model: model)
        _ = try insert("two", model: model)
        model.reload()
        let panel = PanelController(model: model)
        panel.show(placement: .center)
        panel.show(placement: .mouse)
        panel.showFeedback()
        panel.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        panel.showFeedback()
        panel.closePanel()

        let query = AccessibilityClient.queryTrusted
        defer { AccessibilityClient.queryTrusted = query }
        AccessibilityClient.queryTrusted = { _ in false }
        XCTAssertTrue(panel.handle(key(kVK_Escape, "", [])))
        panel.show(placement: .center)
        XCTAssertTrue(panel.handle(key(kVK_Delete, "", [.command])))
        model.confirmClearAll = false
        XCTAssertTrue(panel.handle(key(kVK_Return, "\r", [])))
        XCTAssertTrue(panel.handle(key(kVK_Return, "\r", [.command])))
        XCTAssertTrue(panel.handle(key(kVK_Return, "\r", [.shift])))
        XCTAssertFalse(panel.handle(key(kVK_Delete, "", [])))
        _ = panel.panel.makeFirstResponder(panel.panel.contentView)
        XCTAssertTrue(panel.handle(key(kVK_Delete, "", [])))
        XCTAssertTrue(panel.handle(key(kVK_ANSI_Z, "z", [.command])))
        XCTAssertTrue(panel.handle(key(kVK_ANSI_P, "p", [.command])))
        XCTAssertTrue(panel.handle(key(kVK_ANSI_1, "1", [.command])))
        XCTAssertTrue(panel.handle(key(kVK_ANSI_9, "9", [.command])))
        XCTAssertTrue(panel.handle(key(kVK_DownArrow, "", [])))
        XCTAssertTrue(panel.handle(key(kVK_UpArrow, "", [])))
        model.items = []
        model.reload()
        XCTAssertTrue(panel.handle(key(kVK_DownArrow, "", [])))
        XCTAssertTrue(panel.handle(key(kVK_Delete, "", [.command])))
        XCTAssertFalse(panel.handle(key(kVK_ANSI_A, "a", [])))
        model.confirmClearAll = true
        XCTAssertFalse(panel.handle(key(kVK_Return, "\r", [])))
        model.confirmClearAll = false

        XCTAssertTrue(panel.passesToSearchField(key(kVK_ANSI_Z, "z", [.command]), flags: [.command]))
        XCTAssertTrue(panel.passesToSearchField(key(kVK_ANSI_A, "a", [.command]), flags: [.command]))
        XCTAssertTrue(panel.passesToSearchField(key(kVK_ANSI_C, "c", [.command]), flags: [.command]))
        XCTAssertTrue(panel.passesToSearchField(key(kVK_ANSI_V, "v", [.command]), flags: [.command]))
        XCTAssertTrue(panel.passesToSearchField(key(kVK_ANSI_X, "x", [.command]), flags: [.command]))
        XCTAssertFalse(panel.passesToSearchField(key(kVK_ANSI_P, "p", [.command]), flags: [.command]))
        XCTAssertFalse(panel.passesToSearchField(key(kVK_ANSI_A, "a", [.option]), flags: [.option]))
        XCTAssertTrue(panel.passesToSearchField(key(kVK_Delete, "", []), flags: []))
        XCTAssertTrue(panel.passesToSearchField(key(kVK_ForwardDelete, "", []), flags: []))
        XCTAssertTrue(panel.passesToSearchField(key(kVK_LeftArrow, "", []), flags: []))
        XCTAssertTrue(panel.passesToSearchField(key(kVK_RightArrow, "", []), flags: []))
        XCTAssertTrue(panel.passesToSearchField(key(kVK_Home, "", []), flags: []))
        XCTAssertTrue(panel.passesToSearchField(key(kVK_End, "", []), flags: []))
        XCTAssertFalse(panel.passesToSearchField(key(kVK_ANSI_B, "b", []), flags: []))
        panel.closePanel()
    }

    func testSettingsPreferencesDiagnosticsAndRenderedTabs() throws {
        let (settings, _) = makeSettings()
        settings.maxCount = 0
        settings.maxDays = 0
        _ = settings.retention
        settings.maxCount = 200
        settings.maxDays = 7
        _ = settings.retention
        settings.pasteBehavior = .copyOnly
        settings.panelPlacement = .center
        settings.ignoreConcealed = false
        settings.recordDuringSecureInput = true
        settings.appearance = .light
        settings.appearance = .light
        settings.manuallyPaused = true
        settings.pauseUntil = Date().addingTimeInterval(60)
        settings.hotkeyCode = 3
        settings.hotkeyModifiers = 1
        settings.hotkeyDisplay = "⌘A"
        settings.pauseHotkeyCode = 4
        settings.pauseHotkeyModifiers = 2
        settings.pauseHotkeyDisplay = "⌘B"
        settings.panelWidth = 700
        settings.panelHeight = 500
        for choice in PauseChoice.allCases {
            _ = choice.id
            _ = choice.title
            settings.pauseChoice = choice
        }
        settings.excludedApps = [ExcludedApp(bundleID: "com.example", name: "Example")]
        _ = settings.excludedApps[0].id
        settings.launchAtLogin = true
        settings.launchAtLogin = false

        let suiteName = "coverage-bad-\(UUID().uuidString)"
        suites.append(suiteName)
        let bad = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        bad.set(true, forKey: "didSeedExclusions")
        bad.set(Data("not-json".utf8), forKey: "excludedApps")
        let loaded = AppSettings(defaults: bad)
        XCTAssertTrue(loaded.excludedApps.isEmpty)

        let (model, directory, _) = try makeModel()
        let app = directory.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        model.excludeApp(at: app)
        model.excludeApp(at: app)
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        model.excludeApp(at: finder)
        let json = try XCTUnwrap(model.diagnosticsJSON())
        XCTAssertFalse(json.isEmpty)
        try executeSQL("DROP TABLE items", at: model.store.directory)
        XCTAssertNotNil(model.diagnosticsJSON())

        var windows: [NSWindow] = []
        model.clearAllError = AppModel.clearAllFailedMessage
        model.accessibilityTrusted = false
        model.settings.hotkeyConflict = true
        model.settings.pauseHotkeyDisplay = "⌘⇧P"
        model.settings.pauseHotkeyConflict = true
        for tab in SettingsTab.allCases {
            _ = tab.id
            _ = tab.title
            windows.append(render(SettingsView(initialTab: tab).environmentObject(model)))
        }
        model.accessibilityTrusted = true
        windows.append(render(SettingsView(initialTab: .about).environmentObject(model)))
        _ = windows
    }

    func testHistoryViewsQueriesHashesAndSmallPlatformEdges() throws {
        let (model, directory, _) = try makeModel()
        let file = directory.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        let names = try PropertyListSerialization.data(fromPropertyList: [file.path, "not a path", file.path], format: .binary, options: 0)
        let built = CaptureBuilder.build(PasteboardSnapshot(items: [
            PasteboardItemData(values: [
                PasteboardUTI.fileURL: Data("file://\(file.path)\n/tmp/missing-coverage\nnotaurl".utf8),
                PasteboardUTI.filenames: names
            ])
        ]))
        XCTAssertNotNil(built)
        let image = try imageData()
        let imageBuilt = CaptureBuilder.build(PasteboardSnapshot(items: [
            PasteboardItemData(values: [PasteboardUTI.png: image])
        ]))
        XCTAssertNotNil(imageBuilt)

        let now = Date()
        let pinned = makeItem(kind: .file, text: "a.txt\n b.txt \n", pinned: true)
        XCTAssertTrue(pinned.title.contains("a.txt"))
        let single = makeItem(kind: .file, text: "only.txt")
        XCTAssertEqual(single.title, "only.txt")
        let blank = makeItem(kind: .text, text: "")
        XCTAssertFalse(blank.title.isEmpty)
        let multiline = makeItem(kind: .text, text: "first\nsecond")
        XCTAssertEqual(multiline.title, "first")
        _ = multiline.subtitle
        _ = pinned.subtitle
        XCTAssertEqual(HistoryGrouping.section(for: pinned, now: now), .pinned)
        var earlier = makeItem(kind: .text, text: "old")
        earlier.lastUsedAt = now.addingTimeInterval(-3 * 24 * 60 * 60)
        earlier.createdAt = earlier.lastUsedAt
        XCTAssertEqual(HistoryGrouping.section(for: earlier, now: now), .earlier)
        var yesterday = earlier
        yesterday.lastUsedAt = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        XCTAssertEqual(HistoryGrouping.section(for: yesterday, now: now), .yesterday)
        var today = earlier
        today.lastUsedAt = Calendar.current.startOfDay(for: now).addingTimeInterval(60)
        if today.lastUsedAt < now.addingTimeInterval(-5 * 60) {
            XCTAssertEqual(HistoryGrouping.section(for: today, now: now), .today)
        }
        for section in HistorySection.allCases {
            _ = section.id
            _ = section.title
        }
        let policy = RetentionPolicy(maxCount: 1, maxAge: 10, maxImageBytes: 1)
        let overflow = policy.expiredAndOverflowIDs(in: [pinned, earlier, yesterday], now: now)
        XCTAssertFalse(overflow.isEmpty)
        let images = [
            makeItem(kind: .image, text: "img", byteSize: 5),
            makeItem(kind: .image, text: "img2", byteSize: 5, id: "img2")
        ]
        XCTAssertFalse(policy.imageOverflowIDs(in: images).isEmpty)
        XCTAssertTrue(RetentionPolicy(maxCount: nil, maxAge: nil, maxImageBytes: 100).expiredAndOverflowIDs(in: images, now: now).isEmpty)

        for filter in ItemFilter.allCases {
            _ = HistoryQuery.matches(images[0], query: "IMG", filter: filter)
            _ = HistoryQuery.matches(makeItem(kind: .rich, text: "rich"), query: "", filter: filter)
            _ = HistoryQuery.matches(makeItem(kind: .mixed, text: "mix"), query: "nope", filter: filter)
        }
        XCTAssertEqual(ContentHash.files([
            FileFingerprint(path: "/b", size: 1, modifiedAt: 1),
            FileFingerprint(path: "/a", size: 2, modifiedAt: 2)
        ]).isEmpty, false)
        _ = try AppPaths.supportDirectory()
        let logs = try makeDirectory()
        _ = try AppPaths.logsDirectory(configured: logs.path, useBundleConfiguration: false)
        _ = try AppPaths.logsDirectory(configured: "", useBundleConfiguration: false)
        _ = try AppPaths.logsDirectory(configured: "$(SRCROOT)/logs", useBundleConfiguration: false)
        _ = try AppPaths.logsDirectory(configured: nil, useBundleConfiguration: false)

        _ = FrontmostApp.current()
        XCTAssertNil(FrontmostApp.runningApplication(bundleID: nil))
        _ = FrontmostApp.runningApplication(bundleID: "com.apple.finder")
        _ = AppIconCache.image(bundleID: nil)
        _ = AppIconCache.image(bundleID: "")
        _ = AppIconCache.image(bundleID: "com.apple.finder")
        _ = AppIconCache.image(bundleID: "com.apple.finder")
        _ = AppIconCache.image(bundleID: "missing.coverage.app")
        _ = SecureInput.isEnabled()
        _ = LoginItemController.isEnabled
        try? LoginItemController.setEnabled(false)
        try? LoginItemController.setEnabled(true)
        try? LoginItemController.setEnabled(false)
        _ = HotkeyCodec.display(keyCode: 200, flags: [.command, .shift, .option, .control], fallback: "")
        _ = HotkeyCodec.display(keyCode: UInt16(kVK_ANSI_A), flags: [], fallback: "")

        let backend = CarbonHotkeyBackend()
        let center = HotkeyCenter(backend: backend)
        _ = backend.installHandler(for: center)
        _ = backend.installHandler(for: center)
        let modifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        if backend.register(keyCode: UInt32(kVK_F19), modifiers: modifiers, id: 99) {
            _ = backend.register(keyCode: UInt32(kVK_F19), modifiers: modifiers, id: 99)
            _ = backend.register(keyCode: UInt32(kVK_F18), modifiers: modifiers, id: 99)
        }
        backend.unregister(id: 99)
        backend.unregister(id: 98)
        backend.removeHandler()
        backend.removeHandler()

        let dbDirectory = try makeDirectory()
        let database = try SQLiteDatabase(path: dbDirectory.appendingPathComponent("ok.db").path)
        XCTAssertThrowsError(try database.query("SELECT * FROM missing_table") { _ in })
        let blocker = dbDirectory.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocker)
        XCTAssertThrowsError(try SQLiteDatabase(path: blocker.appendingPathComponent("nested.db").path))

        model.accessibilityTrusted = false
        model.items = []
        var windows = [render(HistoryPanelView().environmentObject(model))]
        let storedImage = try model.store.insertOrTouch(try XCTUnwrap(imageBuilt), sourceBundleID: "com.apple.finder", sourceName: "Finder")
        _ = try PayloadStore(root: directory).writeThumbnail(itemID: storedImage.id, imageData: image)
        let emptyText = CapturedClipboard(kind: .text, plainText: "", contentHash: "empty-text", byteSize: 0, imageWidth: nil, imageHeight: nil, oversize: false, representations: [])
        _ = try model.store.insertOrTouch(emptyText, sourceBundleID: nil, sourceName: "Example")
        let oversize = CapturedClipboard(kind: .text, plainText: "preview", contentHash: "preview-oversize", byteSize: 1, imageWidth: nil, imageHeight: nil, oversize: true, representations: [])
        _ = try model.store.insertOrTouch(oversize, sourceBundleID: "com.example", sourceName: "Example")
        model.reload()
        model.selectedID = storedImage.id
        model.banner = "banner"
        windows.append(render(HistoryPanelView().environmentObject(model)))
        model.selectedID = model.items.first { $0.payloadOversize }?.id
        windows.append(render(HistoryPanelView().environmentObject(model)))
        let view = HistoryPanelView()
        _ = view.contextMenu(makeItem(kind: .text, text: "menu"))
        _ = view.contextMenu(makeItem(kind: .file, text: "menu.txt", pinned: true))
        _ = view.contextMenu(makeItem(kind: .mixed, text: "mix"))
        _ = windows
    }

    func testRemainingCapturePasteStoreAndRenderedActions() throws {
        let limits = CaptureLimits(maxTextBytes: 8, maxImageBytes: 1, previewBytes: 4)
        let utf16 = try XCTUnwrap(CaptureBuilder.build(PasteboardSnapshot(items: [
            PasteboardItemData(values: [PasteboardUTI.utf16: Data("utf16".data(using: .utf16)!)])
        ])))
        XCTAssertEqual(utf16.plainText, "utf16")
        let urlOnly = try XCTUnwrap(CaptureBuilder.build(PasteboardSnapshot(items: [
            PasteboardItemData(values: [PasteboardUTI.url: Data("https://example.com".utf8)])
        ])))
        XCTAssertTrue(urlOnly.plainText.contains("example.com"))
        let richDigest = try XCTUnwrap(CaptureBuilder.build(PasteboardSnapshot(items: [
            PasteboardItemData(values: [:], fullDigests: [PasteboardUTI.html: "html-digest"])
        ])))
        XCTAssertEqual(richDigest.contentHash, "html-digest")
        let richBytes = Data("{\\rtf1 hi}".utf8)
        let rich = try XCTUnwrap(CaptureBuilder.build(PasteboardSnapshot(items: [
            PasteboardItemData(values: [PasteboardUTI.rtf: richBytes])
        ])))
        XCTAssertEqual(rich.contentHash, ContentHash.sha256(richBytes))
        let image = try imageData()
        let mixed = try XCTUnwrap(CaptureBuilder.build(
            PasteboardSnapshot(items: [
                PasteboardItemData(
                    values: [PasteboardUTI.png: image, PasteboardUTI.plain: Data("cap".utf8)],
                    fullDigests: [PasteboardUTI.plain: "plain-digest"],
                    fullByteCounts: [PasteboardUTI.png: 50, PasteboardUTI.plain: 50]
                )
            ]),
            limits: limits
        ))
        XCTAssertFalse(mixed.contentHash.isEmpty)
        let oversizedImage = try XCTUnwrap(CaptureBuilder.build(
            PasteboardSnapshot(items: [
                PasteboardItemData(
                    values: [PasteboardUTI.png: image, PasteboardUTI.plain: Data("cap".utf8)],
                    fullByteCounts: [PasteboardUTI.png: 50]
                )
            ]),
            limits: limits
        ))
        XCTAssertFalse(oversizedImage.contentHash.isEmpty)
        let preview = try XCTUnwrap(CaptureBuilder.build(
            PasteboardSnapshot(items: [
                PasteboardItemData(
                    values: [PasteboardUTI.plain: Data("abcdef".utf8)],
                    fullByteCounts: [PasteboardUTI.plain: 40]
                )
            ]),
            limits: limits
        ))
        XCTAssertFalse(preview.plainText.isEmpty)

        var aged = makeItem(kind: .text, text: "old")
        aged.createdAt = Date(timeIntervalSince1970: 10)
        aged.lastUsedAt = Date(timeIntervalSince1970: 10)
        var fresh = makeItem(kind: .text, text: "new")
        fresh.lastUsedAt = Date(timeIntervalSince1970: 80)
        let picture = makeItem(kind: .image, text: "pic", byteSize: 30)
        let policy = RetentionPolicy(maxCount: 1, maxAge: 50, maxImageBytes: 1)
        XCTAssertFalse(policy.expiredAndOverflowIDs(in: [aged, fresh], now: Date(timeIntervalSince1970: 100)).isEmpty)
        var kept = makeItem(kind: .text, text: "keep")
        kept.lastUsedAt = Date(timeIntervalSince1970: 20)
        var newer = makeItem(kind: .text, text: "newer")
        newer.lastUsedAt = Date(timeIntervalSince1970: 90)
        let overflow = RetentionPolicy(maxCount: 1, maxAge: nil, maxImageBytes: 1)
        XCTAssertEqual(overflow.expiredAndOverflowIDs(in: [kept, newer], now: Date()).count, 1)
        XCTAssertFalse(policy.imageOverflowIDs(in: [picture]).isEmpty)

        let bare = CaptureMonitor(pasteboard: namedPasteboard())
        bare.poll()
        bare.syncChangeCount()

        let (model, directory, _) = try makeModel()
        let repeated = try insert("same-text", model: model)
        let again = try insert("same-text", model: model)
        XCTAssertEqual(again.id, repeated.id)
        let touched = try XCTUnwrap(CaptureBuilder.build(PasteboardSnapshot(items: [
            PasteboardItemData(values: [PasteboardUTI.plain: Data("same-text".utf8)])
        ])))
        _ = try model.store.insertOrTouch(touched, sourceBundleID: nil, sourceName: "Touched")
        try executeSQL("UPDATE items SET kind = 'nope' WHERE id = '\(repeated.id)'", at: directory)
        _ = try model.store.fetchAll()
        let storedImage = try XCTUnwrap(CaptureBuilder.build(PasteboardSnapshot(items: [
            PasteboardItemData(values: [PasteboardUTI.png: image])
        ])))
        _ = try model.store.insertOrTouch(storedImage, sourceBundleID: "com.example", sourceName: "Example")
        try model.store.applyRetention(RetentionPolicy(maxCount: nil, maxAge: nil, maxImageBytes: 1))

        let database = try SQLiteDatabase(path: directory.appendingPathComponent("raise.db").path)
        XCTAssertThrowsError(try database.query("SELECT RAISE(ABORT, 'fail')") { _ in })

        let board = namedPasteboard()
        let fileURL = directory.appendingPathComponent("note.txt")
        try Data("note".utf8).write(to: fileURL)
        let fileItem = makeItem(kind: .file, text: "note.txt")
        let representations = [
            StoredRepresentation(uti: PasteboardUTI.fileURL, storage: "inline", relativePath: nil, inlineValue: fileURL.path)
        ]
        _ = PasteboardWriter.write(item: fileItem, representations: representations, directory: directory, mode: .copyOnly, pasteboard: board)
        var outcomes: [PasteOutcome] = []
        model.pasteService.perform(
            item: makeItem(kind: .text, text: "behavior"),
            representations: [],
            directory: directory,
            mode: .automatic,
            targetBundleID: nil,
            behavior: .copyOnly,
            beginSelfWrite: { _, _ in 1 },
            finishSelfWrite: { _, _ in },
            completion: { outcomes.append($0) }
        )
        XCTAssertEqual(outcomes.count, 1)

        let query = AccessibilityClient.queryTrusted
        let post = KeystrokeSender.postEvent
        let openURL = AccessibilityClient.openURL
        let activate = AccessibilityClient.activateApp
        defer {
            AccessibilityClient.queryTrusted = query
            KeystrokeSender.postEvent = post
            AccessibilityClient.openURL = openURL
            AccessibilityClient.activateApp = activate
        }
        AccessibilityClient.queryTrusted = { _ in false }
        AccessibilityClient.openURL = { _ in }
        AccessibilityClient.activateApp = {}
        KeystrokeSender.postEvent = { _ in }

        model.reload()
        model.selectedID = nil
        model.deleteSelected()
        model.setPinnedDeletePresented(false)
        model.setPinnedDeletePresented(false)
        let pinned = try insert("pinned-row", model: model)
        try model.store.setPinned(id: pinned.id, pinned: true)
        model.reload()
        model.selectedID = pinned.id
        model.deleteSelected()
        XCTAssertTrue(model.confirmPinnedDelete)
        model.selectedID = repeated.id
        model.revealInFinder()
        model.confirmPinnedDelete = false
        model.confirmClearAll = false

        let panel = PanelController(model: model)
        panel.show(placement: .mouse)
        _ = panel.panel.makeFirstResponder(panel.panel.contentView)
        flush()
        _ = panel.panel.makeFirstResponder(panel.panel.contentView)
        panel.panel.sendEvent(key(kVK_DownArrow, "", []))
        model.selectedID = "missing"
        XCTAssertTrue(panel.handle(key(kVK_DownArrow, "", [])))
        panel.panel.resignKey()
        panel.panel.sendEvent(key(kVK_ANSI_B, "b", []))
        panel.show(placement: .center)

        model.paste(mode: .automatic)
        flush()
        AccessibilityClient.queryTrusted = { _ in true }
        model.settings.pasteBehavior = .automatic
        model.selectedID = model.items.first?.id
        model.paste(mode: .automatic)
        let sent = expectation(description: "model paste")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { sent.fulfill() }
        wait(for: [sent], timeout: 2)
        panel.closePanel()

        model.settings.pasteBehavior = .copyOnly
        model.paste(mode: .automatic)
        model.monitor.pasteboard = board
        model.monitor.frontmost = { ("com.example.editor", "Editor") }
        model.monitor.secureInputEnabled = { false }
        model.start()
        try executeSQL("DROP TABLE items", at: directory)
        set(board, values: [PasteboardUTI.plain: Data("ingest-fails".utf8)])
        finish(model.monitor)
        set(board, values: [PasteboardUTI.transient: Data([1])])
        finish(model.monitor)
        set(board, values: [PasteboardUTI.concealed: Data([1]), PasteboardUTI.plain: Data("hidden".utf8)])
        model.settings.ignoreConcealed = true
        finish(model.monitor)
        model.monitor.stop()

        let (failed, failedDirectory, _) = try makeModel()
        let victim = try insert("victim", model: failed)
        failed.reload()
        failed.selectedID = victim.id
        try executeSQL("DROP TABLE items", at: failedDirectory)
        failed.deleteSelected()
        XCTAssertEqual(failed.banner, L10n.text("删除失败", "Couldn't delete"))

        model.settings.excludedApps = [ExcludedApp(bundleID: "com.example", name: "Example")]
        model.settings.pauseHotkeyDisplay = "⌘⇧P"
        model.clearAllError = AppModel.clearAllFailedMessage
        model.confirmClearAll = true
        model.confirmPinnedDelete = true
        var         windows = [
            render(SettingsView(initialTab: .general, recording: .panel, recordMessage: "reserved").environmentObject(model), settle: true),
            render(SettingsView(initialTab: .privacy).environmentObject(model), settle: true),
            render(SettingsView(initialTab: .storage, confirmClear: true).environmentObject(model), settle: true),
            render(SettingsView(initialTab: .about).environmentObject(model), settle: true)
        ]
        for window in windows {
            clickButtons(in: window)
        }
        model.settings.maxCount = 1000
        model.settings.maxDays = 90
        flush()
        NSApp.sendEvent(key(kVK_ANSI_C, "c", [.command]))
        flush()
        for window in NSApp.windows where window.isVisible {
            clickButtons(in: window)
        }

        model.items = [makeItem(kind: .text, text: ""), makeItem(kind: .file, text: "note.txt"), picture]
        model.selectedID = model.items[0].id
        model.banner = "shown"
        windows.append(render(HistoryPanelView().environmentObject(model), size: NSSize(width: 500, height: 420), settle: true))
        model.selectedID = picture.id
        windows.append(render(HistoryPanelView().environmentObject(model), size: NSSize(width: 900, height: 520), settle: true))
        for window in windows {
            clickButtons(in: window)
        }
        flush()
        for window in NSApp.windows where window.isVisible {
            clickButtons(in: window)
        }
        _ = windows
    }

    private func finish(_ monitor: CaptureMonitor) {
        let done = expectation(description: "poll")
        monitor.onPollFinished = { done.fulfill() }
        monitor.poll()
        wait(for: [done], timeout: 2)
    }

    private func flush() {
        let done = expectation(description: "flush")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    private func makeSettings() -> (AppSettings, String) {
        let suite = "coverage-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), suite)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    private func makeModel() throws -> (AppModel, URL, String) {
        let (settings, suite) = makeSettings()
        let directory = try makeDirectory()
        let model = AppModel(store: try HistoryStore(directory: directory), settings: settings)
        model.hotkeys = FakeGlobalHotkeys()
        model.pasteService.pasteboard = namedPasteboard()
        return (model, directory, suite)
    }

    @discardableResult
    private func insert(_ text: String, model: AppModel) throws -> ClipboardItem {
        let captured = try XCTUnwrap(CaptureBuilder.build(PasteboardSnapshot(items: [
            PasteboardItemData(values: [PasteboardUTI.plain: Data(text.utf8)])
        ])))
        return try model.store.insertOrTouch(captured, sourceBundleID: "com.example", sourceName: "Example")
    }

    private func makeItem(kind: ItemKind, text: String, oversize: Bool = false, pinned: Bool = false, byteSize: Int = 4, id: String = UUID().uuidString) -> ClipboardItem {
        ClipboardItem(
            id: id,
            kind: kind,
            plainText: text,
            contentHash: id,
            sourceBundleID: "com.example",
            sourceName: "Example",
            createdAt: Date(),
            lastUsedAt: Date(),
            pinned: pinned,
            pinOrder: pinned ? 1 : nil,
            byteSize: byteSize,
            imageWidth: kind == .image ? 2 : nil,
            imageHeight: kind == .image ? 2 : nil,
            payloadOversize: oversize
        )
    }

    private func namedPasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("coverage-\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    private func set(_ board: NSPasteboard, values: [String: Data]) {
        board.clearContents()
        let item = NSPasteboardItem()
        for (uti, data) in values {
            item.setData(data, forType: NSPasteboard.PasteboardType(uti))
        }
        board.writeObjects([item])
    }

    private func key(_ code: Int, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(code)
        )!
    }

    private func render<V: View>(_ view: V, size: NSSize = NSSize(width: 720, height: 480), settle: Bool = false) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: view)
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
        window.orderFront(nil)
        if settle {
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func clickButtons(in window: NSWindow) {
        pressAccessibleButtons(of: window)
    }

    private func pressAccessibleButtons(of window: NSWindow) {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        for button in accessibleButtons(element) where !skipsModalTitle(accessibleTitle(button)) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
        _ = window
    }

    private func accessibleButtons(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        let children = value as? [AXUIElement] ?? []
        var buttons: [AXUIElement] = []
        for child in children {
            if accessibleRole(child) == (kAXButtonRole as String) {
                buttons.append(child)
            }
            buttons.append(contentsOf: accessibleButtons(child))
        }
        return buttons
    }

    private func accessibleRole(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String ?? ""
    }

    private func accessibleTitle(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        if let title = value as? String, !title.isEmpty { return title }
        var description: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description)
        return description as? String ?? ""
    }

    private func skipsModalTitle(_ title: String) -> Bool {
        let blocked = ["添加", "Add app", "导出", "Export", "开机", "Launch at login"]
        return title.isEmpty || blocked.contains { title.contains($0) }
    }

    private func imageData() throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 8,
            bitsPerPixel: 32
        ) else {
            throw StoreError.open("bitmap")
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func executeSQL(_ sql: String, at directory: URL) throws {
        var handle: OpaquePointer?
        let path = directory.appendingPathComponent("history.db").path
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            throw StoreError.open("open")
        }
        defer { sqlite3_close(handle) }
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard code == SQLITE_OK else {
            throw StoreError.sql(message.map { String(cString: $0) } ?? sql)
        }
    }
}
