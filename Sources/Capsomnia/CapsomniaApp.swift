import AppKit
import Carbon.HIToolbox
import CapsomniaControl
import Foundation

final class Capsomnia: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var lastAppliedState: Bool?
    private var lastConfirmedSleepState: Bool?
    private var settingsHeaderStatus = SettingsHeaderStatus.error
    private var failedSleepState: Bool?
    private var nextSleepStateRetryAt = Date.distantPast
    private var nextSleepStateVerificationAt = Date.distantPast
    private var nextDisplaySleepRetryAt = Date.distantPast
    private var nextDisplayAwakeRetryAt = Date.distantPast
    private var nextClosedLidDimmingRetryAt = Date.distantPast
    private let displayAwakeAssertion = DisplayAwakeAssertion()
    private let closedLidDimmingController = ClosedLidDisplayDimmingController()
    private lazy var hotspotKeepAlive = MobileHotspotKeepAlive(log: { [weak self] message in
        self?.log(message)
    })
    private lazy var lidOpenLockController: LidOpenLockController = {
        let controller = LidOpenLockController(record: Preferences.lastLidOpenLock,
                                              requestLock: ScreenLock.request,
                                              save: { Preferences.lastLidOpenLock = $0 })
        controller.onChange = { [weak self] event in
            self?.log("lid_open_lock outcome=\(event.outcome.rawValue) opened_at=\(event.openedAt.timeIntervalSince1970) requested_at=\(event.requestedAt?.timeIntervalSince1970 ?? 0) confirmed_at=\(event.confirmedAt?.timeIntervalSince1970 ?? 0)")
        }
        return controller
    }()
    private var sessionTimer = SessionAutoOffTimer()
    private var controlServer: ControlServer?
    private var isControlMutationInFlight = false
    private var isAutoOffToggleInFlight = false
    private var secureInputCapsLockOverrideActive = false
    private var secureInputOverrideSuppressedForExplicitOff = false
    private var nextSecureInputCapsLockRetryAt = Date.distantPast
    private var didRequestDisplaySleepForClosedLid = false
    private var hasLoggedMissingClamshellState = false
    private var hasLoggedMissingDimmingClamshellState = false
    private var hasLoggedMissingCapsLockState = false
    private var hasLoggedMissingDisplayState = false
    private var hasLoggedMissingSleepState = false
    private var dedicatedModeError = false
    private var shouldRestoreSleepOnTerminate = true
    private var pollingTimer: Timer?
    private var pendingAutoOffPreferenceApplyWorkItem: DispatchWorkItem?
    private var globalCapsLockEventMonitor: Any?
    private var localCapsLockEventMonitor: Any?
    private var signalSources: [DispatchSourceSignal] = []
    private var statusItem: NSStatusItem?
    private weak var autoOffStatusMenuItem: NSMenuItem?
    private var autoOffPresetMenuItems: [NSMenuItem] = []
    private weak var autoOffCustomMenuItem: NSMenuItem?
    private weak var lidLockMenuItem: NSMenuItem?
    private weak var keepDisplayAwakeStatusMenuItem: NSMenuItem?
    private weak var checkForUpdatesMenuItem: NSMenuItem?
    private var updateController: UpdateController?
    private lazy var toolsDownloadController: ToolsDownloadController = {
        let controller = ToolsDownloadController()
        controller.onDownloadingChange = { [weak self] downloading in
            self?.settingsWindowController?.updateToolsDownloading(downloading)
        }
        controller.onStatusChange = { [weak self] message in
            self?.settingsWindowController?.updateToolsMessage(message)
        }
        return controller
    }()
    private var settingsWindowController: SettingsWindowController?
    private let onImage = DotImage.make(color: Brand.led)
    private let offImage = DotImage.make(color: NSColor(calibratedWhite: 0.58, alpha: 1.0))
    private let errorImage = DotImage.make(color: .systemRed)
    private let capsLockStateReader = SystemCapsLockStateReader()
    private lazy var capsLockHold: CapsLockHoldController = CapsLockHoldController(
        initialAwake: SleepStateReader.isDisabled() ?? false,
        onRequest: { [weak self] target in
            DispatchQueue.main.async {
                guard let self, self.capsLockHold.requestedAwake == target else { return }
                self.log("capslock_hold elapsed_ms=\(Int((self.capsLockHold.lastHoldDuration ?? 0) * 1000)) target=\(target)")
                self.requestCapsLockState(target, source: "capslock_hold", preserveHold: true)
            }
        },
        setLED: { [weak self] target, completion in
            guard let self else { completion(.unavailable); return }
            self.capsLockToggleCoordinator.requestSet(target) { [weak self] result in
                self?.handleCapsLockToggleResult(result, source: "led_sync")
                completion(result)
                self?.refreshSettingsHeaderStatus()
            }
        }
    )
    private lazy var hidCapsLockMonitor: HIDCapsLockMonitor = {
        let monitor = HIDCapsLockMonitor()
        monitor.onChange = { [weak self] in
            self?.handleHIDCapsLockChange()
        }
        return monitor
    }()
    private var nextHIDCapsLockMonitorCheckAt = Date.distantPast
    private lazy var dedicatedCapsLockFilter: DedicatedCapsLockFilter = {
        let filter = DedicatedCapsLockFilter()
        filter.onCapsLockChange = { [weak self] in
            // The tap also sees programmatic changes. Use it as a prompt to
            // read the hardware, not as evidence of a user's ON/OFF intent.
            self?.refreshAfterCapsLockEvent()
        }
        return filter
    }()
    private let capsLockToggleCoordinator = CapsLockToggleCoordinator()
    private let autoOffSleepCoordinator = AutoOffSleepCoordinator()
    private let globalHotKeyManager = GlobalHotKeyManager()
    private lazy var secureInputFocusMonitor = SecureInputFocusMonitor { [weak self] in
        self?.applyCurrentCapsLockState(reason: "secure_input_focus")
    }
    private var nextDedicatedModeRetryAt = Date.distantPast
    private let helperRetryInterval: TimeInterval = 5
    private let dedicatedModeRetryInterval: TimeInterval = 5
    private let sleepStateVerificationInterval: TimeInterval = 10
    private let selectedKeyboardInputSourceChangedNotificationName = Notification.Name(
        kTISNotifySelectedKeyboardInputSourceChanged as String
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfNewerInteractiveDuplicate() {
            return
        }

        restoreSavedDisplayBrightnessIfNeeded(reason: "startup")
        Preferences.registerDefaults()
        restoreSavedSecureInputCapsLockIfNeeded(reason: "startup")

        let controller = UpdateController(log: { [weak self] message in
            self?.log(message)
        })
        controller.onAvailableVersionChange = { [weak self] in
            self?.updateStatusMenuControls()
            self?.settingsWindowController?.updateAvailableVersion(self?.updateController?.availableVersion)
        }
        updateController = controller

        configureGlobalHotKey()
        let shouldShowInitialSetup = Preferences.consumeForceWelcomeOnNextLaunch()
            || !Preferences.didCompleteInitialSetup

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOpenSettingsNotification),
            name: openSettingsNotificationName,
            object: appLabel
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSelectedKeyboardInputSourceChanged),
            name: selectedKeyboardInputSourceChangedNotificationName,
            object: nil
        )

        NSApp.setActivationPolicy(.accessory)
        syncStatusItemVisibility()
        installCapsLockEventMonitors()
        installSignalHandlers()
        installPollingMonitor()
        log("start")
        applyCurrentCapsLockState(reason: "startup")
        startControlServer()

        if shouldShowInitialSetup {
            showSettingsWindow(page: .initialPreferences)
        } else if ProcessInfo.processInfo.arguments.contains("--show-settings") {
            showSettingsWindow(page: .settings)
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateController?.cleanUpInstallerIfNeeded()
            self?.updateController?.autoCheckIfDue()
            self?.updateController?.startAutoCheckTimer()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow(page: currentSettingsPage())
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
        capsLockHold.cancelPress()
        hidCapsLockMonitor.stop()
        dedicatedCapsLockFilter.stop()
        secureInputFocusMonitor.stop()
        if let globalCapsLockEventMonitor {
            NSEvent.removeMonitor(globalCapsLockEventMonitor)
        }
        if let localCapsLockEventMonitor {
            NSEvent.removeMonitor(localCapsLockEventMonitor)
        }
        globalCapsLockEventMonitor = nil
        localCapsLockEventMonitor = nil
        pendingAutoOffPreferenceApplyWorkItem?.cancel()
        pendingAutoOffPreferenceApplyWorkItem = nil
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if closedLidDimmingController.isDimmed {
            let restored = closedLidDimmingController.setDimmed(false)
            log("terminate built_in_display_restore succeeded=\(restored ? "true" : "false")")
        }
        displayAwakeAssertion.setActive(false)
        hotspotKeepAlive.setActive(false)
        guard shouldRestoreSleepOnTerminate else { return }

        Preferences.secureInputCapsLockOverrideActive = false
        let ledResult = SystemCapsLockController.set(false)
        log("terminate led_off result=\(ledResult)")
        let result = runHelper("off")
        log("terminate restore_off helper_status=\(result.status) stdout=\(result.stdout) stderr=\(result.stderr)")
    }

    private func terminateIfNewerInteractiveDuplicate() -> Bool {
        guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != appLabel else {
            return false
        }

        let currentPID = getpid()
        let olderInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: appLabel)
            .filter { !$0.isTerminated && $0.processIdentifier > 0 && $0.processIdentifier < currentPID }

        guard let existing = olderInstances.min(by: { $0.processIdentifier < $1.processIdentifier }) else {
            return false
        }

        shouldRestoreSleepOnTerminate = false
        DistributedNotificationCenter.default().post(
            name: openSettingsNotificationName,
            object: appLabel,
            userInfo: nil
        )
        existing.activate(options: [])
        log("duplicate_instance existing_pid=\(existing.processIdentifier) terminate_without_restore")
        NSApp.terminate(nil)
        return true
    }

    @objc private func handleOpenSettingsNotification(_ notification: Notification) {
        showSettingsWindow(page: currentSettingsPage())
    }

    @objc private func handleSelectedKeyboardInputSourceChanged(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleSelectedKeyboardInputSourceChanged(notification)
            }
            return
        }

        refreshAfterCapsLockEvent()
    }

    private func installCapsLockEventMonitors() {
        ensureHIDCapsLockMonitor(promptForPermission: true)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(restartHIDCapsLockMonitorAfterWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        let capsLockKeyCode = UInt16(kVK_CapsLock)
        globalCapsLockEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged
        ) { [weak self] event in
            guard event.keyCode == capsLockKeyCode else { return }
            DispatchQueue.main.async {
                self?.handleObservedCapsLockChange()
            }
        }
        localCapsLockEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged
        ) { [weak self] event in
            if event.keyCode == capsLockKeyCode {
                self?.handleObservedCapsLockChange()
            }
            return event
        }
        log(
            "capslock_key_monitor global=\(globalCapsLockEventMonitor != nil ? "active" : "unavailable")"
        )
    }

    @objc private func restartHIDCapsLockMonitorAfterWake(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.capsLockHold.cancelPress()
            self.hidCapsLockMonitor.stop()
            self.nextHIDCapsLockMonitorCheckAt = .distantPast
            self.ensureHIDCapsLockMonitor()
            self.applyCurrentCapsLockState(reason: "wake")
        }
    }

    private func ensureHIDCapsLockMonitor(promptForPermission: Bool = false) {
        let now = Date()
        guard now >= nextHIDCapsLockMonitorCheckAt else { return }
        nextHIDCapsLockMonitorCheckAt = now.addingTimeInterval(helperRetryInterval)
        let previous = hidCapsLockMonitor.state
        let state = hidCapsLockMonitor.start(promptForPermission: promptForPermission)
        if state != previous {
            log("capslock_hid_monitor state=\(state) observing=\(hidCapsLockMonitor.isActive)")
        }
    }

    private func handleObservedCapsLockChange() {
        refreshAfterCapsLockEvent()
    }

    private func handleHIDCapsLockChange() {
        let pressed = hidCapsLockMonitor.isPressed
        log("capslock_hid \(pressed ? "pressed" : "released") uptime=\(hidCapsLockMonitor.lastEventTime)")
        guard !isAutoOffInProgress, !isControlMutationInFlight else {
            capsLockHold.cancelPress()
            return
        }
        capsLockHold.handle(pressed: pressed, now: hidCapsLockMonitor.lastEventTime)
        refreshAfterCapsLockEvent()
    }

    private func refreshAfterCapsLockEvent() {
        DispatchQueue.main.async { [weak self] in
            self?.applyCurrentCapsLockState(reason: "capslock_event")
            self?.refreshSettingsHeaderStatus()
        }
    }

    private var isAutoOffInProgress: Bool {
        isAutoOffToggleInFlight || autoOffSleepCoordinator.isPending
    }

    /// Power intent only changes after a completed hold or an explicit control.
    private var currentCapsLockState: Bool { capsLockHold.requestedAwake }

    private func syncStatusItemVisibility() {
        if Preferences.showMenuBarIcon {
            if statusItem == nil {
                installStatusItem()
            }

            refreshStatus(capsLockOn: currentCapsLockState)
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 24)
        statusItem = item

        if let button = item.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = appName
        }

        log("status_item installed visible=\(item.isVisible) length=\(item.length) button=\(item.button != nil)")

        rebuildStatusMenu()
        updateStatus(capsLockOn: false)
    }

    private func rebuildStatusMenu() {
        guard let item = statusItem else { return }

        let strings = AppStrings.current()
        let menu = NSMenu()
        menu.delegate = self
        let toggleCapsLockItem = NSMenuItem(
            title: strings.toggleCapsLock,
            action: #selector(toggleCapsLockFromMenu),
            keyEquivalent: ""
        )
        toggleCapsLockItem.target = self
        menu.addItem(toggleCapsLockItem)
        menu.addItem(NSMenuItem.separator())

        let autoOffItem = NSMenuItem(title: strings.autoOffTimer, action: nil, keyEquivalent: "")
        let autoOffMenu = NSMenu(title: strings.autoOffTimer)
        autoOffMenu.delegate = self
        autoOffPresetMenuItems = []

        for minutes in [0] + AutoOffPreset.minuteOptions {
            let presetItem = NSMenuItem(
                title: minutes == 0
                    ? strings.autoOffOff
                    : AutoOffFormatter.durationLabel(minutes: minutes),
                action: #selector(selectAutoOffPreset),
                keyEquivalent: ""
            )
            presetItem.target = self
            presetItem.representedObject = minutes
            autoOffMenu.addItem(presetItem)
            autoOffPresetMenuItems.append(presetItem)
        }

        autoOffMenu.addItem(NSMenuItem.separator())
        let customItem = NSMenuItem(
            title: "\(strings.autoOffCustom)…",
            action: #selector(openAutoOffSettings),
            keyEquivalent: ""
        )
        customItem.target = self
        autoOffMenu.addItem(customItem)
        autoOffCustomMenuItem = customItem
        menu.setSubmenu(autoOffMenu, for: autoOffItem)
        menu.addItem(autoOffItem)
        autoOffStatusMenuItem = autoOffItem

        let keepDisplayAwakeItem = NSMenuItem(
            title: strings.keepDisplayAwake,
            action: #selector(toggleKeepDisplayAwakeFromMenu),
            keyEquivalent: ""
        )
        keepDisplayAwakeItem.target = self
        menu.addItem(keepDisplayAwakeItem)
        keepDisplayAwakeStatusMenuItem = keepDisplayAwakeItem
        let lockItem = NSMenuItem(title: LidOpenLockText.current.title,
                                 action: #selector(toggleLidLockFromMenu), keyEquivalent: "")
        lockItem.target = self
        lockItem.indentationLevel = 1
        menu.addItem(lockItem)
        lidLockMenuItem = lockItem

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: strings.openCapsomnia, action: #selector(openCapsomnia), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let updatesItem = NSMenuItem(
            title: strings.checkForUpdates,
            action: #selector(checkForUpdatesFromMenu),
            keyEquivalent: ""
        )
        updatesItem.target = self
        menu.addItem(updatesItem)
        checkForUpdatesMenuItem = updatesItem

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: strings.quit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        updateStatusMenuControls()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateStatusMenuControls()
        updateController?.autoCheckIfDue()
    }

    @objc private func checkForUpdatesFromMenu() {
        if let availableVersion = updateController?.availableVersion {
            updateController?.promptDownload(version: availableVersion)
        } else {
            updateController?.checkNow()
        }
    }

    @objc private func toggleCapsLockFromMenu() {
        // NSMenu tracks in a non-default run loop mode. Scheduling in the
        // default mode lets the action return and menu tracking finish before
        // changing the real modifier-lock state.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            self?.requestCapsLockToggle(source: "menu")
        }
    }

    private func requestCapsLockToggle(source: String) {
        requestCapsLockState(!currentCapsLockState, source: source)
    }

    private func requestCapsLockState(_ target: Bool, source: String, preserveHold: Bool = false) {
        prepareSecureInputOverrideForExplicitTarget(target, preserveHold: preserveHold)
        capsLockHold.setRequested(target, preservePress: true)
        nextSleepStateRetryAt = .distantPast
        nextSleepStateVerificationAt = .distantPast
        log("\(source) awake_requested=\(target ? "on" : "off")")
        applyCurrentCapsLockState(reason: source)
    }

    private func handleCapsLockToggleResult(
        _ result: CapsLockToggleResult,
        source: String
    ) {
        switch result {
        case let .changed(target):

            log("\(source)_toggle_capslock target=\(target ? "on" : "off") succeeded=true")
        case .unavailable:

            log("\(source)_toggle_capslock failed=hid_system_unavailable")
        case let .writeFailed(target):

            log("\(source)_toggle_capslock target=\(target ? "on" : "off") failed=write_state")
        case let .verificationFailed(target, actual):

            let actualValue = actual.map { $0 ? "on" : "off" } ?? "unknown"
            log(
                "\(source)_toggle_capslock target=\(target ? "on" : "off")"
                    + " failed=verification actual=\(actualValue)"
            )
        }
        refreshSettingsHeaderStatus()
    }

    @objc private func selectAutoOffPreset(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        guard AutoOffMenuSelectionPolicy.shouldApply(
            currentMinutes: Preferences.autoOffMinutes,
            selectedMinutes: minutes
        ) else { return }
        setAutoOffMinutes(minutes)
    }

    @objc private func openAutoOffSettings() {
        showSettingsWindow(page: currentSettingsPage())
    }

    @objc private func toggleLidLockFromMenu() {
        setLidLockEnabled(!Preferences.lockOnLidOpen)
    }

    private func setLidLockEnabled(_ enabled: Bool) {
        Preferences.lockOnLidOpen = enabled
        settingsWindowController?.reloadText()
        updateStatusMenuControls()
        log("preference lock_on_lid_open=\(enabled ? "on" : "off")")
    }

    @objc private func toggleKeepDisplayAwakeFromMenu() {
        setKeepDisplayAwake(!Preferences.keepDisplayAwake)
    }

    @objc private func openCapsomnia() {
        showSettingsWindow(page: currentSettingsPage())
    }

    @objc private func quit() {
        log("menu_quit")
        NSApp.terminate(nil)
    }

    private func showSettingsWindow(page: SettingsPage) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                onDedicatedCapsLockModeChange: { [weak self] enabled in
                    self?.setDedicatedCapsLockMode(enabled)
                },
                onShowMenuBarIconChange: { [weak self] enabled in
                    self?.setShowMenuBarIcon(enabled)
                },
                onLanguageChange: { [weak self] language in
                    self?.setLanguage(language)
                },
                onLaunchAtLoginChange: { [weak self] enabled in
                    do {
                        try self?.setLaunchAtLogin(enabled)
                    } catch {
                        self?.rebuildStatusMenu()
                        self?.log("preference launch_at_login_error=\(error.localizedDescription)")
                    }
                },
                onKeepDisplayAwakeChange: { [weak self] enabled in
                    self?.setKeepDisplayAwake(enabled)
                },
                onKeepHotspotAliveChange: { [weak self] enabled in
                    self?.setKeepHotspotAlive(enabled)
                },
                onIgnoreExternalCapsLockOffWhileLidClosedChange: { [weak self] enabled in
                    self?.setIgnoreExternalCapsLockOffWhileLidClosed(enabled)
                },
                onHideCapsLockIndicatorChange: { [weak self] hidden in
                    self?.setHideCapsLockIndicator(hidden)
                },
                capsLockIndicatorStateProvider: { [weak self] in
                    self?.capsLockIndicatorDisplayState()
                        ?? CapsLockIndicatorDisplayState(hidden: false, restartPending: false)
                },
                onAutoOffMinutesChange: { [weak self] minutes in
                    self?.setAutoOffMinutes(minutes)
                },
                onAutoOffRestart: { [weak self] in
                    self?.restartAutoOff()
                },
                autoOffDisplayProvider: { [weak self] in
                    self?.autoOffDisplayState() ?? .idle(minutes: 0)
                },
                onKeyboardShortcutChange: { [weak self] shortcut in
                    self?.setKeyboardShortcut(shortcut) ?? false
                },
                onKeyboardShortcutRecordingChange: { [weak self] isRecording in
                    self?.setKeyboardShortcutRecording(isRecording)
                },
                onAutomaticUpdateChecksChange: { [weak self] enabled in
                    self?.setAutomaticUpdateChecks(enabled)
                },
                onFinishInitialSetup: { [weak self] in
                    Preferences.didCompleteInitialSetup = true
                    self?.log("initial_setup_complete")
                },
                onUpdate: { [weak self] version in
                    self?.updateController?.promptDownload(version: version)
                },
                onReleaseNotes: { [weak self] version in
                    self?.updateController?.openReleaseNotes(version: version)
                },
                onToolsDownload: { [weak self] in
                    self?.toolsDownloadController.promptDownload(from: self?.settingsWindowController?.window)
                },
                autoOffDescriptionProvider: { [weak self] in self?.sessionTimerDescription() },
                onLidOpenLockChange: { [weak self] enabled in self?.setLidLockEnabled(enabled) }
            )
        }

        settingsWindowController?.updateAvailableVersion(updateController?.availableVersion)
        settingsWindowController?.updateToolsDownloading(toolsDownloadController.isDownloading)
        refreshSettingsHeaderStatus()
        settingsWindowController?.updateHeaderStatus(settingsHeaderStatus)
        settingsWindowController?.show(page: page)
    }

    private func currentSettingsPage() -> SettingsPage {
        Preferences.didCompleteInitialSetup ? .settings : .initialPreferences
    }

    private func setShowMenuBarIcon(_ enabled: Bool) {
        Preferences.showMenuBarIcon = enabled
        syncStatusItemVisibility()
        rebuildStatusMenu()
        settingsWindowController?.reloadText()
        log("preference show_menu_bar_icon=\(enabled ? "on" : "off")")
    }

    private func setDedicatedCapsLockMode(_ enabled: Bool) {
        Preferences.dedicatedCapsLockMode = enabled
        nextDedicatedModeRetryAt = .distantPast

        if !enabled {
            dedicatedCapsLockFilter.stop()
            secureInputFocusMonitor.stop()
            dedicatedModeError = false
        }

        let ready = ensureDedicatedCapsLockFilter(
            promptForPermission: enabled,
            reason: "preference"
        )
        syncStatusItemVisibility()
        rebuildStatusMenu()
        applyCurrentCapsLockState(reason: "preference")
        settingsWindowController?.reloadText()
        log(
            "preference dedicated_caps_lock_mode=\(enabled ? "on" : "off")"
                + " filter_ready=\(ready ? "yes" : "no")"
        )
    }

    private func setLanguage(_ language: AppLanguage) {
        guard Preferences.language != language else { return }
        Preferences.language = language
        rebuildStatusMenu()

        refreshStatus(capsLockOn: currentCapsLockState)
        settingsWindowController?.reloadText()
        log("preference language=\(language.rawValue)")
    }

    private func setLaunchAtLogin(_ enabled: Bool) throws {
        try LaunchAgentManager.setEnabled(enabled)
        Preferences.launchAtLogin = enabled
        rebuildStatusMenu()
        log("preference launch_at_login=\(enabled ? "on" : "off")")
    }

    private func setAutomaticUpdateChecks(_ enabled: Bool) {
        Preferences.automaticUpdateChecks = enabled
        log("preference automatic_update_checks=\(enabled ? "on" : "off")")
    }

    private func setKeepDisplayAwake(_ enabled: Bool) {
        Preferences.keepDisplayAwake = enabled
        let capsLockOn = currentCapsLockState
        if enabled {
            didRequestDisplaySleepForClosedLid = false
            nextDisplaySleepRetryAt = .distantPast
        }
        syncDisplayAwakeAssertion(
            capsLockOn: capsLockOn,
            sleepPreventionConfirmed: failedSleepState == nil && lastAppliedState == capsLockOn,
            reason: "preference"
        )
        if !enabled {
            evaluateDisplaySleepForClosedLid(capsLockOn: capsLockOn, reason: "preference")
        }
        updateStatusMenuControls()
        settingsWindowController?.reloadText()
        log("preference keep_display_awake=\(enabled ? "on" : "off")")
    }

    private func setKeepHotspotAlive(_ enabled: Bool) {
        Preferences.keepHotspotAlive = enabled
        syncHotspotKeepAlive(capsLockOn: currentCapsLockState, reason: "preference")
        settingsWindowController?.reloadText()
        log("preference keep_hotspot_alive=\(enabled ? "on" : "off")")
    }

    private func setIgnoreExternalCapsLockOffWhileLidClosed(_ enabled: Bool) {
        Preferences.ignoreExternalCapsLockOffWhileLidClosed = enabled
        log("preference ignore_external_capslock_off_while_lid_closed=\(enabled ? "on" : "off")")
    }

    /// The indicator toggle reflects the on-disk feature-flag override, so a
    /// failed helper call simply leaves the toggle on its previous state when
    /// the window reloads.
    private func setHideCapsLockIndicator(_ hidden: Bool) {
        let result = runHelper(hidden ? indicatorHideHelperMode : indicatorShowHelperMode)
        let applied = result.status == 0 && CapsLockIndicatorFeatureFlag.isHidden() == hidden
        log(
            "preference hide_caps_lock_indicator=\(hidden ? "on" : "off")"
                + " helper_status=\(result.status) applied=\(applied)"
                + " stdout=\(result.stdout) stderr=\(result.stderr)"
        )
        settingsWindowController?.reloadText()
    }

    private func capsLockIndicatorDisplayState() -> CapsLockIndicatorDisplayState {
        let hidden = CapsLockIndicatorFeatureFlag.isHidden()
        let evaluation = CapsLockIndicatorRestartPolicy.evaluate(
            snapshot: Preferences.capsLockIndicatorBootSnapshot,
            currentBootTime: SystemBootTimeReader.bootTime(),
            currentHidden: hidden
        )
        if evaluation.snapshot != Preferences.capsLockIndicatorBootSnapshot {
            Preferences.capsLockIndicatorBootSnapshot = evaluation.snapshot
        }
        return CapsLockIndicatorDisplayState(
            hidden: hidden,
            restartPending: evaluation.restartPending
        )
    }

    /// Advance the auto-off timer and, if it has elapsed, turn awake mode off.
    /// Returns `true` when an auto-off was triggered this call.
    @discardableResult
    private func evaluateAutoOff(capsLockOn: Bool, reason: String) -> Bool {
        let previousSource = sessionTimer.source
        let didFire = sessionTimer.evaluate(
            capsLockOn: capsLockOn,
            defaultMinutes: Preferences.autoOffMinutes,
            now: Date()
        )
        if previousSource != sessionTimer.source { settingsWindowController?.reloadText() }
        if didFire {
            fireAutoOff(reason: reason)
        }
        return didFire
    }

    private func fireAutoOff(reason: String) {
        guard !isAutoOffToggleInFlight else { return }
        isAutoOffToggleInFlight = true
        prepareSecureInputOverrideForExplicitTarget(false)

        log("auto_off elapsed reason=\(reason)")
        capsLockToggleCoordinator.requestSet(false) { [weak self] result in
            guard let self else { return }
            self.isAutoOffToggleInFlight = false
            if result == .changed(to: false) { self.capsLockHold.setRequested(false) }
            self.autoOffSleepCoordinator.recordCapsLockResult(result)
            self.handleCapsLockToggleResult(result, source: "auto_off")
            self.applyCurrentCapsLockState(reason: "auto_off")
        }
    }

    private func setAutoOffMinutes(_ minutes: Int, preserveSessionOverride: Bool = false) {
        Preferences.autoOffMinutes = minutes
        // CLI settings alter the default without replacing a one-shot timer.
        if !preserveSessionOverride || sessionTimer.overrideSeconds == nil {
            sessionTimer.reset()
        }
        updateStatusMenuControls()
        settingsWindowController?.reloadText()
        log("preference auto_off_minutes=\(minutes)")

        // Let AppKit paint the selected value before querying pmset/helper state,
        // and coalesce rapid +/- clicks so only the final value is re-applied.
        pendingAutoOffPreferenceApplyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingAutoOffPreferenceApplyWorkItem = nil
            self.applyCurrentCapsLockState(reason: "preference")
        }
        pendingAutoOffPreferenceApplyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func restartAutoOff() {
        sessionTimer.restart(
            capsLockOn: currentCapsLockState,
            defaultMinutes: Preferences.autoOffMinutes,
            now: Date()
        )
        log("auto_off restart")
        applyCurrentCapsLockState(reason: "restart")
    }

    private func autoOffDisplayState() -> AutoOffDisplayState {
        let minutes = Preferences.autoOffMinutes
        guard currentCapsLockState else {
            return .idle(minutes: minutes)
        }
        let seconds = sessionTimer.duration(defaultMinutes: minutes)
        guard seconds > 0 else { return .infinite }
        if let deadline = sessionTimer.deadline {
            return .counting(remaining: max(0, deadline.timeIntervalSinceNow))
        }
        return .counting(remaining: seconds)
    }

    private func updateStatusMenuControls() {
        let strings = AppStrings.current()
        let selectedMinutes = Preferences.autoOffMinutes

        autoOffStatusMenuItem?.title = AutoOffMenuFormatter.title(
            base: strings.autoOffTimer,
            turnsOffIn: strings.autoOffTurnsOffIn,
            state: autoOffDisplayState()
        )
        for item in autoOffPresetMenuItems {
            guard let minutes = item.representedObject as? Int else { continue }
            item.state = minutes == selectedMinutes ? .on : .off
        }
        autoOffCustomMenuItem?.title = AutoOffMenuFormatter.customTitle(
            base: strings.autoOffCustom,
            selectedMinutes: selectedMinutes
        ) + "…"
        autoOffCustomMenuItem?.state = selectedMinutes > 0
            && !AutoOffPreset.isQuickPick(selectedMinutes) ? .on : .off
        keepDisplayAwakeStatusMenuItem?.state = Preferences.keepDisplayAwake ? .on : .off
        lidLockMenuItem?.title = LidOpenLockText.current.title
        lidLockMenuItem?.state = Preferences.lockOnLidOpen ? .on : .off
        lidLockMenuItem?.isHidden = !Preferences.keepDisplayAwake
        checkForUpdatesMenuItem?.title = updateController?.availableVersion.map {
            String(format: strings.updateAvailableMenuFormat, $0)
        } ?? strings.checkForUpdates
    }

    private func configureGlobalHotKey() {
        globalHotKeyManager.onTrigger = { [weak self] in
            self?.requestCapsLockToggle(source: "shortcut")
        }

        let shortcut = Preferences.keyboardShortcut
        let status = globalHotKeyManager.replaceShortcut(with: shortcut)
        guard status == noErr else {
            Preferences.keyboardShortcut = nil
            log("shortcut_register startup_failed status=\(status)")
            return
        }

        if let shortcut {
            log("shortcut_register startup=\(shortcut.displayValue) succeeded=true")
        }
    }

    private func setKeyboardShortcut(_ shortcut: KeyboardShortcut?) -> Bool {
        let status = globalHotKeyManager.replaceShortcut(with: shortcut)
        guard status == noErr else {
            log(
                "shortcut_register value=\(shortcut?.displayValue ?? "none")"
                    + " failed_status=\(status)"
            )
            return false
        }

        Preferences.keyboardShortcut = shortcut
        log("preference keyboard_shortcut=\(shortcut?.displayValue ?? "none")")
        return true
    }

    private func setKeyboardShortcutRecording(_ isRecording: Bool) {
        if isRecording {
            globalHotKeyManager.suspend()
            return
        }

        let status = globalHotKeyManager.replaceShortcut(
            with: Preferences.keyboardShortcut
        )
        guard status != noErr else { return }

        Preferences.keyboardShortcut = nil
        settingsWindowController?.reloadText()
        log("shortcut_register resume_failed status=\(status)")
    }

    private func pollLidOpenLock() {
        let awake = currentCapsLockState && lastAppliedState == true && failedSleepState == nil
        let eligible = Preferences.lockOnLidOpen && Preferences.keepDisplayAwake && awake
        lidOpenLockController.poll(closed: ClamshellStateReader.isClosed(), eligible: eligible,
                                   locked: ScreenLock.isLocked(), now: Date())
    }

    private func installPollingMonitor() {
        pollingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.applyCurrentCapsLockState(reason: "poll")
            self?.refreshSettingsHeaderStatus()
            self?.pollLidOpenLock()
        }
        timer.tolerance = 0.05
        pollingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        log("polling_ready interval_ms=250 tolerance_ms=50")
    }

    private func applyCurrentCapsLockState(reason: String) {
        ensureHIDCapsLockMonitor()
        guard !isAutoOffToggleInFlight, !isControlMutationInFlight else { return }
        capsLockHold.poll(pressed: hidCapsLockMonitor.isPressed, now: HIDCapsLockMonitor.uptime)
        _ = ensureDedicatedCapsLockFilter(promptForPermission: false, reason: reason)
        let requested = capsLockHold.requestedAwake
        if evaluateAutoOff(capsLockOn: requested, reason: reason) { return }
        apply(capsLockOn: requested, reason: reason)
        if let physical = capsLockStateReader.currentState() {
            _ = syncSecureInputCapsLockOverride(physicalCapsLockOn: physical, reason: reason)
        }
        capsLockHold.synchronizeLED(
            physical: capsLockStateReader.currentState(), pressed: hidCapsLockMonitor.isPressed,
            secureOverride: secureInputCapsLockOverrideActive, now: HIDCapsLockMonitor.uptime
        )
        refreshStatus(capsLockOn: lastConfirmedSleepState ?? requested)
    }

    private func ensureDedicatedCapsLockFilter(
        promptForPermission: Bool,
        reason: String
    ) -> Bool {
        guard Preferences.dedicatedCapsLockMode else {
            if dedicatedCapsLockFilter.state != .inactive {
                dedicatedCapsLockFilter.stop()
            }
            dedicatedModeError = false
            nextDedicatedModeRetryAt = .distantPast
            return true
        }

        if dedicatedCapsLockFilter.isActive {
            secureInputFocusMonitor.start()
            dedicatedModeError = false
            nextDedicatedModeRetryAt = .distantPast
            return true
        }

        let now = Date()
        guard promptForPermission || now >= nextDedicatedModeRetryAt else {
            dedicatedModeError = true
            return false
        }

        let state = dedicatedCapsLockFilter.start(
            promptForPermission: promptForPermission
        )
        let isReady = state == .active
        if isReady {
            secureInputFocusMonitor.start()
        }
        dedicatedModeError = !isReady
        nextDedicatedModeRetryAt = isReady
            ? .distantPast
            : now.addingTimeInterval(dedicatedModeRetryInterval)
        log("\(reason) dedicated_caps_lock_filter=\(String(describing: state))")
        return isReady
    }

    private func prepareSecureInputOverrideForExplicitTarget(_ target: Bool, preserveHold: Bool = false) {
        if !preserveHold { capsLockHold.cancelPress() }
        if target {
            secureInputOverrideSuppressedForExplicitOff = false
            return
        }

        secureInputCapsLockOverrideActive = false
        Preferences.secureInputCapsLockOverrideActive = false
        secureInputOverrideSuppressedForExplicitOff = true
        nextSecureInputCapsLockRetryAt = .distantPast
    }

    /// Temporarily decouple the physical Caps Lock state from Capsomnia's
    /// logical awake state while a secure text field owns Secure Event Input.
    /// Returning `true` keeps sleep prevention and status UI logically on.
    private func syncSecureInputCapsLockOverride(
        physicalCapsLockOn: Bool,
        reason: String
    ) -> Bool {
        let snapshot = SecureInputStateReader.snapshot()
        let logicalCapsomniaActive = lastAppliedState == true
            && !secureInputOverrideSuppressedForExplicitOff
        let action = SecureInputCapsLockPolicy.action(
            dedicatedModeEnabled: Preferences.dedicatedCapsLockMode,
            capsomniaActive: logicalCapsomniaActive,
            overrideActive: secureInputCapsLockOverrideActive,
            snapshot: snapshot
        )
        switch action {
        case .none:
            return physicalCapsLockOn

        case .activate, .keepActive:
            if action == .keepActive, !physicalCapsLockOn {
                return true
            }
            let now = Date()
            guard now >= nextSecureInputCapsLockRetryAt else {
                return action == .keepActive ? true : physicalCapsLockOn
            }
            let result = SystemCapsLockController.set(false)
            let succeeded = result == .changed(to: false)
            if succeeded {
                secureInputCapsLockOverrideActive = true
                Preferences.secureInputCapsLockOverrideActive = true
                nextSecureInputCapsLockRetryAt = .distantPast
            } else {
                nextSecureInputCapsLockRetryAt = now.addingTimeInterval(helperRetryInterval)
            }
            log(
                "\(reason) secure_input_capslock=off"
                    + " action=\(action == .activate ? "activate" : "reassert")"
                    + " succeeded=\(succeeded ? "true" : "false")"
                    + " result=\(String(describing: result))"
            )
            return succeeded || action == .keepActive ? true : physicalCapsLockOn

        case .restore:
            let now = Date()
            guard now >= nextSecureInputCapsLockRetryAt else { return true }
            let result = SystemCapsLockController.set(true)
            let succeeded = result == .changed(to: true)
            if succeeded {
                secureInputCapsLockOverrideActive = false
                Preferences.secureInputCapsLockOverrideActive = false
                nextSecureInputCapsLockRetryAt = .distantPast
            } else {
                nextSecureInputCapsLockRetryAt = now.addingTimeInterval(helperRetryInterval)
            }
            log(
                "\(reason) secure_input_capslock=on action=restore"
                    + " succeeded=\(succeeded ? "true" : "false")"
                    + " result=\(String(describing: result))"
            )
            return true

        case .deactivateWithoutRestore:
            secureInputCapsLockOverrideActive = false
            Preferences.secureInputCapsLockOverrideActive = false
            nextSecureInputCapsLockRetryAt = .distantPast
            log("\(reason) secure_input_capslock override=cleared_without_restore")
            return physicalCapsLockOn
        }
    }

    /// Hold the display-awake assertion exactly while the preference is on
    /// and confirmed awake mode is active. Idempotent, so it is safe to call
    /// from every apply pass.
    private func syncDisplayAwakeAssertion(
        capsLockOn: Bool,
        sleepPreventionConfirmed: Bool,
        reason: String
    ) {
        let shouldHold = KeepDisplayAwakePolicy.shouldHoldAssertion(
            preferenceEnabled: Preferences.keepDisplayAwake,
            capsLockOn: capsLockOn,
            sleepPreventionConfirmed: sleepPreventionConfirmed
        )
        if !shouldHold {
            // Restore while the display assertion is still active. Releasing
            // it first can make the built-in panel unavailable under a closed lid.
            syncClosedLidDisplayDimming(
                capsLockOn: capsLockOn,
                sleepPreventionConfirmed: sleepPreventionConfirmed,
                reason: reason
            )
        }

        let now = Date()
        if shouldHold != displayAwakeAssertion.isActive,
           now >= nextDisplayAwakeRetryAt {
            let succeeded = displayAwakeAssertion.setActive(shouldHold)
            nextDisplayAwakeRetryAt = succeeded
                ? .distantPast
                : now.addingTimeInterval(helperRetryInterval)
            log(
                "\(reason) display_awake_assertion=\(shouldHold ? "on" : "off")"
                    + " succeeded=\(succeeded ? "true" : "false")"
            )
        }

        if shouldHold {
            syncClosedLidDisplayDimming(
                capsLockOn: capsLockOn,
                sleepPreventionConfirmed: sleepPreventionConfirmed,
                reason: reason
            )
        }
    }

    /// Runs the hotspot keep-alive timer exactly while the preference is on
    /// and awake mode is active. Idempotent, so it is safe to call from every
    /// apply pass.
    private func syncHotspotKeepAlive(capsLockOn: Bool, reason: String) {
        let shouldRun = MobileHotspotKeepAlivePolicy.shouldRun(
            preferenceEnabled: Preferences.keepHotspotAlive,
            capsLockOn: capsLockOn
        )
        guard shouldRun != hotspotKeepAlive.isActive else { return }
        let succeeded = hotspotKeepAlive.setActive(shouldRun)
        log(
            "\(reason) hotspot_keepalive=\(shouldRun ? "on" : "off")"
                + " succeeded=\(succeeded ? "true" : "false")"
        )
    }

    private func restoreSavedDisplayBrightnessIfNeeded(reason: String) {
        guard closedLidDimmingController.isDimmed else { return }
        let restored = closedLidDimmingController.setDimmed(false)
        log("\(reason) built_in_display_crash_restore succeeded=\(restored ? "true" : "false")")
    }

    private func restoreSavedSecureInputCapsLockIfNeeded(reason: String) {
        guard Preferences.secureInputCapsLockOverrideActive else { return }
        let result = SystemCapsLockController.set(true)
        let succeeded = result == .changed(to: true)
        if succeeded {
            Preferences.secureInputCapsLockOverrideActive = false
        }
        log(
            "\(reason) secure_input_capslock_crash_restore"
                + " succeeded=\(succeeded ? "true" : "false")"
                + " result=\(String(describing: result))"
        )
    }

    private func syncClosedLidDisplayDimming(
        capsLockOn: Bool,
        sleepPreventionConfirmed: Bool,
        reason: String
    ) {
        let modeCanDim = Preferences.keepDisplayAwake
            && capsLockOn
            && sleepPreventionConfirmed
            && displayAwakeAssertion.isActive
        let clamshellClosed = modeCanDim ? ClamshellStateReader.isClosed() : nil

        if modeCanDim, clamshellClosed == nil {
            if !hasLoggedMissingDimmingClamshellState {
                log("\(reason) clamshell_state_unavailable")
                hasLoggedMissingDimmingClamshellState = true
            }
        } else if clamshellClosed != nil {
            hasLoggedMissingDimmingClamshellState = false
        }

        let shouldDim = ClosedLidDisplayDimmingPolicy.shouldDim(
            keepDisplayAwake: Preferences.keepDisplayAwake,
            capsLockOn: capsLockOn,
            sleepPreventionConfirmed: sleepPreventionConfirmed,
            displayAwakeAssertionActive: displayAwakeAssertion.isActive,
            clamshellClosed: clamshellClosed
        )
        guard shouldDim != closedLidDimmingController.isDimmed else { return }

        let now = Date()
        guard now >= nextClosedLidDimmingRetryAt else { return }
        let succeeded = closedLidDimmingController.setDimmed(shouldDim)
        nextClosedLidDimmingRetryAt = succeeded
            ? .distantPast
            : now.addingTimeInterval(helperRetryInterval)
        log(
            "\(reason) built_in_display=\(shouldDim ? "dimmed" : "restored")"
                + " succeeded=\(succeeded ? "true" : "false")"
        )
    }

    private func apply(capsLockOn: Bool, reason: String) {
        if !capsLockOn, closedLidDimmingController.isDimmed {
            // Restore before the helper reenables system sleep. With a closed
            // lid, waiting until after that transition can be too late.
            syncClosedLidDisplayDimming(
                capsLockOn: false,
                sleepPreventionConfirmed: false,
                reason: reason
            )
        }

        let now = Date()
        if failedSleepState == capsLockOn, now < nextSleepStateRetryAt {
            return
        }

        if lastAppliedState == capsLockOn {
            if failedSleepState == nil, now < nextSleepStateVerificationAt {
                syncDisplayAwakeAssertion(
                    capsLockOn: capsLockOn,
                    sleepPreventionConfirmed: true,
                    reason: reason
                )
                syncHotspotKeepAlive(capsLockOn: capsLockOn, reason: reason)
                evaluateDisplaySleepForClosedLid(capsLockOn: capsLockOn, reason: reason)
                return
            }

            guard let actualState = SleepStateReader.isDisabled() else {
                if !hasLoggedMissingSleepState {
                    log("\(reason) sleep_state_unavailable")
                    hasLoggedMissingSleepState = true
                }
                markSleepStateFailed(capsLockOn, at: now)
                return
            }

            hasLoggedMissingSleepState = false
            if actualState == capsLockOn {
                markSleepStateConfirmed(capsLockOn, at: now, reason: reason)
                return
            }

            log("\(reason) sleep_state_drift expected=\(capsLockOn ? "on" : "off") actual=\(actualState ? "on" : "off")")
        }

        let mode = capsLockOn ? "on" : "off"
        let result = runHelper(mode)
        log("\(reason) capslock=\(mode) helper_status=\(result.status) stdout=\(result.stdout) stderr=\(result.stderr)")

        guard result.status == 0 else {
            markSleepStateFailed(capsLockOn, at: now, resetVerification: false)
            return
        }

        lastAppliedState = capsLockOn
        let confirmedState = SleepStateReader.isDisabled()
        guard confirmedState == Optional(capsLockOn) else {
            hasLoggedMissingSleepState = confirmedState == nil
            log("\(reason) sleep_state_confirmation_failed expected=\(mode) actual=\(confirmedState.map { $0 ? "on" : "off" } ?? "unknown")")
            markSleepStateFailed(capsLockOn, at: now)
            return
        }

        markSleepStateConfirmed(capsLockOn, at: now, reason: reason)
    }

    private func markSleepStateFailed(_ capsLockOn: Bool, at now: Date, resetVerification: Bool = true) {
        failedSleepState = capsLockOn
        nextSleepStateRetryAt = now.addingTimeInterval(helperRetryInterval)
        if resetVerification {
            nextSleepStateVerificationAt = nextSleepStateRetryAt
        }
        syncDisplayAwakeAssertion(
            capsLockOn: capsLockOn,
            sleepPreventionConfirmed: false,
            reason: "sleep_state_failed"
        )
        syncHotspotKeepAlive(capsLockOn: capsLockOn, reason: "sleep_state_failed")
        updateStatusError()
    }

    private func markSleepStateConfirmed(_ capsLockOn: Bool, at now: Date, reason: String) {
        lastConfirmedSleepState = capsLockOn
        hasLoggedMissingSleepState = false
        failedSleepState = nil
        nextSleepStateRetryAt = .distantPast
        nextSleepStateVerificationAt = now.addingTimeInterval(sleepStateVerificationInterval)
        syncStatusItemVisibility()
        syncDisplayAwakeAssertion(
            capsLockOn: capsLockOn,
            sleepPreventionConfirmed: true,
            reason: reason
        )
        syncHotspotKeepAlive(capsLockOn: capsLockOn, reason: reason)
        evaluateDisplaySleepForClosedLid(capsLockOn: capsLockOn, reason: reason)
        requestSystemSleepAfterAutoOffIfReady(capsLockOn: capsLockOn, reason: reason)
    }

    private func requestSystemSleepAfterAutoOffIfReady(capsLockOn: Bool, reason: String) {
        let wasPending = autoOffSleepCoordinator.isPending
        let clamshellClosed = ClamshellStateReader.isClosed()
        if wasPending, capsLockOn {
            log("\(reason) auto_off_sleep canceled=capslock_on")
        } else if wasPending, clamshellClosed != true {
            log("\(reason) auto_off_sleep canceled=lid_not_closed")
        } else if wasPending {
            log("\(reason) auto_off_sleep requested")
        }

        guard let result = autoOffSleepCoordinator.requestSleepIfReady(
            capsLockOn: capsLockOn, clamshellClosed: clamshellClosed
        ) else {
            return
        }

        log(
            "\(reason) auto_off_sleep status=\(result.status)"
                + " stdout=\(result.stdout) stderr=\(result.stderr)"
        )
    }

    private func evaluateDisplaySleepForClosedLid(capsLockOn: Bool, reason: String) {
        guard !Preferences.keepDisplayAwake else {
            didRequestDisplaySleepForClosedLid = false
            nextDisplaySleepRetryAt = .distantPast
            return
        }

        guard capsLockOn else {
            didRequestDisplaySleepForClosedLid = false
            nextDisplaySleepRetryAt = .distantPast
            return
        }

        guard let clamshellClosed = ClamshellStateReader.isClosed() else {
            didRequestDisplaySleepForClosedLid = false
            if !hasLoggedMissingClamshellState {
                log("\(reason) clamshell_state_unavailable")
                hasLoggedMissingClamshellState = true
            }
            return
        }
        hasLoggedMissingClamshellState = false

        guard clamshellClosed else {
            didRequestDisplaySleepForClosedLid = false
            nextDisplaySleepRetryAt = .distantPast
            return
        }

        let externalDisplayConnected = ExternalDisplayReader.isConnected()
        if externalDisplayConnected != nil {
            hasLoggedMissingDisplayState = false
        }
        guard DisplaySleepPolicy.shouldRequestDisplaySleep(
            keepDisplayAwake: Preferences.keepDisplayAwake,
            externalDisplayConnected: externalDisplayConnected
        ) else {
            didRequestDisplaySleepForClosedLid = false
            nextDisplaySleepRetryAt = .distantPast
            if externalDisplayConnected == nil, !hasLoggedMissingDisplayState {
                log("\(reason) external_display_state_unavailable")
                hasLoggedMissingDisplayState = true
            }
            return
        }

        guard !didRequestDisplaySleepForClosedLid else { return }
        let now = Date()
        guard now >= nextDisplaySleepRetryAt else { return }

        let result = runHelper(displaySleepHelperMode)
        log("\(reason) clamshell=closed display_sleep_status=\(result.status) stdout=\(result.stdout) stderr=\(result.stderr)")
        if result.status == 0 {
            didRequestDisplaySleepForClosedLid = true
            nextDisplaySleepRetryAt = .distantPast
        } else {
            nextDisplaySleepRetryAt = now.addingTimeInterval(helperRetryInterval)
        }
    }

    private func refreshSettingsHeaderStatus() {
        let physical = capsLockStateReader.currentState()
        let ledTarget = secureInputCapsLockOverrideActive ? false : currentCapsLockState
        let ledMismatch = !hidCapsLockMonitor.isPressed && physical != ledTarget
        settingsHeaderStatus = SettingsHeaderStatus.resolve(
            confirmed: lastConfirmedSleepState,
            hasError: dedicatedModeError || !hidCapsLockMonitor.isActive || failedSleepState != nil || ledMismatch,
            changing: isControlMutationInFlight || isAutoOffToggleInFlight,
            previous: settingsHeaderStatus
        )
        settingsWindowController?.updateHeaderStatus(settingsHeaderStatus)
    }

    private func updateStatus(capsLockOn: Bool) {
        refreshSettingsHeaderStatus()
        guard let button = statusItem?.button else { return }
        let strings = AppStrings.current()
        let confirmed = lastConfirmedSleepState ?? capsLockOn
        button.image = confirmed ? onImage : offImage
        button.toolTip = confirmed ? strings.tooltipOn : strings.tooltipOff
    }

    private func refreshStatus(capsLockOn: Bool) {
        let ledTarget = secureInputCapsLockOverrideActive ? false : currentCapsLockState
        let ledReady = hidCapsLockMonitor.isPressed || capsLockStateReader.currentState() == ledTarget
        if failedSleepState == nil, !dedicatedModeError, hidCapsLockMonitor.isActive, ledReady {
            updateStatus(capsLockOn: capsLockOn)
        } else {
            updateStatusError()
        }
    }

    private func updateStatusError() {
        refreshSettingsHeaderStatus()
        if statusItem == nil {
            installStatusItem()
        }
        guard let button = statusItem?.button else { return }
        button.image = errorImage
        let strings = AppStrings.current()
        button.toolTip = dedicatedModeError && failedSleepState == nil
            ? strings.tooltipDedicatedPermission
            : strings.tooltipError
    }

    private func runHelper(_ mode: String) -> (status: Int32, stdout: String, stderr: String) {
        CommandRunner.run("/usr/bin/sudo", ["-n", helperPath, mode])
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        for signalNumber in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.dedicatedCapsLockFilter.stop()
                self?.secureInputFocusMonitor.stop()
                Preferences.secureInputCapsLockOverrideActive = false
                let ledResult = SystemCapsLockController.set(false)
                self?.log("signal=\(signalNumber) led_off result=\(ledResult)")
                let result = self?.runHelper("off")
                self?.log(
                    "signal=\(signalNumber) restore_off helper_status=\(result?.status ?? -1) "
                        + "stdout=\(result?.stdout ?? "") stderr=\(result?.stderr ?? "")"
                )
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        let url = URL(fileURLWithPath: logPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logPath),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}


// MARK: - Local CLI control
extension Capsomnia {
    private func startControlServer() {
        do {
            let server = try ControlServer(bundleIdentifier: appLabel) { [weak self] request, reply in
                guard let self else {
                    reply(ControlResponse(ok: false, error: "Capsomnia is shutting down."))
                    return
                }
                self.handleControl(request, reply: reply)
            }
            try server.start()
            controlServer = server
        } catch {
            log("cli_server failed=\(error.localizedDescription)")
        }
    }

    private func handleControl(_ request: ControlRequest, reply: @escaping (ControlResponse) -> Void) {
        guard request.version == 1 else {
            reply(ControlResponse(ok: false, error: "CLI/app protocol mismatch. Update both together."))
            return
        }
        let args = request.arguments
        func fail(_ message: String) { reply(ControlResponse(ok: false, error: message)) }
        func succeed(_ value: JSONValue) { reply(ControlResponse(ok: true, result: value)) }
        if args == ["status"] { succeed(controlStatus()); return }
        if args == ["doctor"] { succeed(controlDoctor()); return }
        if args == ["timer", "status"] { succeed(controlTimerStatus()); return }
        if args.count >= 2 && args[0...1] == ["settings", "get"] {
            let settings = controlSettings()
            if args.count == 2 { succeed(.object(settings)); return }
            if args.count == 3, let value = settings[args[2]] { succeed(.object([args[2]: value])); return }
            fail("Unknown setting. Run cpsm settings get."); return
        }
        guard !isControlMutationInFlight && !isAutoOffToggleInFlight && !autoOffSleepCoordinator.isPending else {
            fail("A power operation is already in progress. Check status before trying again."); return
        }
        if args == ["on"] || args == ["off"] || args == ["toggle"] {
            guard capsLockStateReader.currentState() != nil else {
                fail("Caps Lock state is unavailable."); return
            }
            let target = args[0] == "toggle" ? !currentCapsLockState : args[0] == "on"
            requestControlState(target, reply: reply)
            return
        }
        if args.count == 3 && args[0...1] == ["timer", "set"] {
            guard let seconds = ControlInput.duration(args[2]) else {
                fail("Use a duration from 1s to 24h, for example 90m or 2h."); return
            }
            requestControlState(true, timerSeconds: seconds, reply: reply)
            return
        }
        if args == ["timer", "cancel"] {
            guard capsLockStateReader.currentState() != nil else {
                fail("Caps Lock state is unavailable."); return
            }
            if currentCapsLockState { sessionTimer.cancel() } else { sessionTimer.reset() }
            updateStatusMenuControls()
            settingsWindowController?.reloadText()
            succeed(controlTimerStatus()); return
        }
        if args == ["timer", "restart"] {
            guard currentCapsLockState, sessionTimer.deadline != nil else {
                fail("There is no running timer. Use cpsm timer set <duration>."); return
            }
            restartAutoOff()
            settingsWindowController?.reloadText()
            succeed(controlTimerStatus()); return
        }
        if args.count == 4 && args[0...1] == ["settings", "set"] {
            do {
                try setControlSetting(args[2], value: args[3])
                settingsWindowController?.reloadText()
                succeed(.object([args[2]: controlSettings()[args[2]] ?? .null]))
            } catch { fail(error.localizedDescription) }
            return
        }
        fail("Unknown command. Run cpsm --help.")
    }

    private func requestControlState(
        _ target: Bool,
        timerSeconds: TimeInterval? = nil,
        reply: @escaping (ControlResponse) -> Void
    ) {
        if target {
            _ = ensureDedicatedCapsLockFilter(promptForPermission: false, reason: "cli")
        }
        prepareSecureInputOverrideForExplicitTarget(target)
        isControlMutationInFlight = true

        ExplicitAwakeCommand.run(
            target: target,
            setCapsLock: { value, completion in
                self.capsLockToggleCoordinator.requestSet(value, completion: completion)
            },
            synchronize: { value in

                self.capsLockHold.setRequested(value)
                if let timerSeconds {
                    self.sessionTimer.set(seconds: timerSeconds, now: Date())
                }
                _ = self.sessionTimer.evaluate(
                    capsLockOn: value, defaultMinutes: Preferences.autoOffMinutes, now: Date()
                )
                self.nextSleepStateRetryAt = .distantPast
                self.nextSleepStateVerificationAt = .distantPast
                self.apply(capsLockOn: value, reason: "cli")
                return self.failedSleepState == nil && SleepStateReader.isDisabled() == value
            },
            readCapsLock: { self.capsLockStateReader.currentState() },
            sleep: { SystemSleepRequester.request() },
            completion: { result in
                self.isControlMutationInFlight = false
                self.refreshSettingsHeaderStatus()
                self.updateStatusMenuControls()
                self.settingsWindowController?.reloadText()
                switch result {
                case .success(let sleepRequested):
                    reply(ControlResponse(ok: true, result: self.controlStatus(sleepRequested: sleepRequested)))
                case .failure(let error):
                    reply(ControlResponse(ok: false, error: error.localizedDescription))
                }
            }
        )
    }

    private func controlStatus(sleepRequested: Bool = false) -> JSONValue {
        let physicalCapsLock = capsLockStateReader.currentState()
        return .object([
            "app_running": .bool(true),
            "app_version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"),
            "caps_lock_hold_ready": .bool(hidCapsLockMonitor.isActive),
            "caps_lock_off_hold_seconds": .number(CapsLockHoldController.minimumDuration),
            "app_path": .string(Bundle.main.bundlePath),
            "caps_lock": .bool(currentCapsLockState),
            "hold_mode": .string("symmetric"),
            "last_hold_seconds": capsLockHold.lastHoldDuration.map(JSONValue.number) ?? .null,
            "led_sync_in_flight": .bool(capsLockHold.isSynchronizingLED),
            "caps_lock_physical": physicalCapsLock.map(JSONValue.bool) ?? .null,
            "secure_input_caps_lock_override": .bool(secureInputCapsLockOverrideActive),
            "sleep_disabled": SleepStateReader.isDisabled().map(JSONValue.bool) ?? .null,
            "sleep_requested": .bool(sleepRequested),
            "timer": controlTimerStatus()
        ])
    }

    private func sessionTimerDescription() -> String? {
        guard sessionTimer.overrideSeconds != nil else { return nil }
        let cancelled = sessionTimer.overrideSeconds == 0
        switch Preferences.language {
        case .japanese:
            return cancelled
                ? "今回のタイマーは解除済みです。下の設定は次回オン時に適用されます。"
                : "CLIで設定した今回限りのタイマーです。下の保存済み設定は変更されません。"
        case .english:
            return cancelled
                ? "Timer cancelled for this session. Saved settings below apply next time."
                : "One-shot CLI timer. Your saved settings below are unchanged."
        case .korean:
            return cancelled
                ? "이번 타이머는 취소되었습니다. 아래 저장된 설정은 다음에 적용됩니다."
                : "CLI로 설정한 일회성 타이머입니다. 아래 저장된 설정은 유지됩니다."
        case .simplifiedChinese:
            return cancelled
                ? "本次定时器已取消。下方保存的设置将在下次开启时应用。"
                : "CLI 设置的一次性定时器。下方保存的设置保持不变。"
        }
    }

    private func controlTimerStatus() -> JSONValue {
        let deadline = sessionTimer.deadline
        return .object([
            "active": .bool(deadline != nil),
            "source": .string(sessionTimer.source),
            "duration_seconds": .number(sessionTimer.duration(defaultMinutes: Preferences.autoOffMinutes)),
            "remaining_seconds": deadline.map { .number(max(0, $0.timeIntervalSinceNow)) } ?? .null,
            "deadline": deadline.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "saved_minutes": .number(Double(Preferences.autoOffMinutes))
        ])
    }

    private func controlSettings() -> [String: JSONValue] {
        [
            "dedicated-caps-lock-mode": .bool(Preferences.dedicatedCapsLockMode),
            "show-menu-bar-icon": .bool(Preferences.showMenuBarIcon),
            "language": .string(Preferences.language.rawValue),
            "launch-at-login": .bool(Preferences.launchAtLogin),
            "keep-display-awake": .bool(Preferences.keepDisplayAwake),
            "keep-hotspot-alive": .bool(Preferences.keepHotspotAlive),
            "ignore-external-caps-lock-off-while-lid-closed": .bool(Preferences.ignoreExternalCapsLockOffWhileLidClosed),
            "auto-off-minutes": .number(Double(Preferences.autoOffMinutes)),
            "automatic-update-checks": .bool(Preferences.automaticUpdateChecks),
            "shortcut": Preferences.keyboardShortcut.map { .string($0.displayValue) } ?? .null
        ]
    }

    private func setControlSetting(_ key: String, value: String) throws {
        if key == "language" {
            guard let language = AppLanguage(rawValue: value) else {
                throw ExplicitAwakeCommand.Failure("Language must be en, ja, ko or zh-Hans.")
            }
            setLanguage(language)
            return
        }
        if key == "auto-off-minutes" {
            guard let minutes = Int(value), (0...AutoOffPreset.maxCustomMinutes).contains(minutes) else {
                throw ExplicitAwakeCommand.Failure("auto-off-minutes must be 0...1440.")
            }
            setAutoOffMinutes(minutes, preserveSessionOverride: true)
            return
        }
        if key == "shortcut" {
            throw ExplicitAwakeCommand.Failure("Shortcut registration is available only in the app settings.")
        }
        guard let enabled = ControlInput.boolean(value) else {
            throw ExplicitAwakeCommand.Failure("Use on/off or true/false for a boolean setting.")
        }
        switch key {
        case "dedicated-caps-lock-mode":
            setDedicatedCapsLockMode(enabled)
            if dedicatedModeError {
                throw ExplicitAwakeCommand.Failure("Setting saved, but capitalization prevention is unavailable. Check Accessibility permission. Awake mode and timers remain available.")
            }
        case "show-menu-bar-icon": setShowMenuBarIcon(enabled)
        case "launch-at-login": try setLaunchAtLogin(enabled)
        case "keep-display-awake": setKeepDisplayAwake(enabled)
        case "keep-hotspot-alive": setKeepHotspotAlive(enabled)
        case "ignore-external-caps-lock-off-while-lid-closed": setIgnoreExternalCapsLockOffWhileLidClosed(enabled)
        case "automatic-update-checks": setAutomaticUpdateChecks(enabled)
        default: throw ExplicitAwakeCommand.Failure("Unknown setting. Run cpsm settings get.")
        }
    }

    private func controlDoctor() -> JSONValue {
        let helperExists = FileManager.default.isExecutableFile(atPath: helperPath)
        let capsLock = capsLockStateReader.currentState()
        let sleepDisabled = SleepStateReader.isDisabled()
        var issues: [JSONValue] = []
        if !helperExists { issues.append(.string("Privileged helper missing. Install the Capsomnia app package.")) }
        if capsLock == nil { issues.append(.string("Caps Lock state is unavailable.")) }
        if sleepDisabled == nil { issues.append(.string("Sleep prevention state is unavailable.")) }
        if let sleepDisabled, sleepDisabled != currentCapsLockState {
            issues.append(.string("Requested awake mode and actual sleep prevention are not synchronized."))
        }
        if !hidCapsLockMonitor.isPressed, capsLock != (secureInputCapsLockOverrideActive ? false : currentCapsLockState) {
            issues.append(.string("Caps Lock LED is not synchronized with awake mode."))
        }
        if dedicatedModeError { issues.append(.string("Capitalization prevention is unavailable. Check Accessibility permission.")) }
        if !hidCapsLockMonitor.isActive {
            issues.append(.string("Long-press detection is unavailable. Check Input Monitoring permission and keyboard connection."))
        }
        return .object([
            "healthy": .bool(issues.isEmpty), "issues": .array(issues),
            "helper_available": .bool(helperExists), "status": controlStatus(),
            "launch_agent_installed": .bool(FileManager.default.fileExists(atPath: "/Library/LaunchAgents/\(appLabel).plist") || FileManager.default.fileExists(atPath:
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/LaunchAgents/\(appLabel).plist").path))
        ])
    }
}
