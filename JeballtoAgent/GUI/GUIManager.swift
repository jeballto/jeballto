import Cocoa
import Virtualization

enum GUIError: Error, LocalizedError {
  case screenshotFailed(String)

  var errorDescription: String? {
    switch self {
    case .screenshotFailed(let message): "Screenshot failed: \(message)"
    }
  }
}

@MainActor final class GUIManager {
  private var windows: [UUID: NSWindow] = [:]
  private var vmViews: [UUID: VZVirtualMachineView] = [:]
  // Strong refs needed because NSWindow.delegate is weak
  private var windowDelegates: [UUID: GUIWindowDelegate] = [:]
  private var hiddenWindows: [UUID: NSWindow] = [:]
  private var hiddenViews: [UUID: VZVirtualMachineView] = [:]
  private var activeKeystrokeUsers: [UUID: Int] = [:]
  private var removeHiddenViewWhenUnused: Set<UUID> = []
  private var appActivated = false
  private let eventBus: EventBus
  private nonisolated let eventProcessor = SerialAsyncProcessor()
  private var eventSubscription: EventBus.SubscriptionToken?

  init(eventBus: EventBus) {
    self.eventBus = eventBus

    eventSubscription = eventBus.subscribe { [weak self] event in
      guard let self else { return }
      eventProcessor.submit { @MainActor [weak self] in
        self?.handleEvent(event)
      }
    }
  }

  isolated deinit {
    eventProcessor.cancel()
    if let token = eventSubscription { eventBus.unsubscribe(token) }
  }

  // MARK: - Public API

  func openGUI(vmId: UUID, virtualMachine: VZVirtualMachine, vmName: String) {
    if let existingWindow = windows[vmId] {
      existingWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      logInfo("GUI already open for VM \(vmId), brought to front", category: "GUIManager")
      return
    }

    activateAppIfNeeded()

    // Reparent an existing off-screen view so in-flight keystrokes keep the same display target.
    let vmView = takeHiddenView(vmId: vmId) ?? Self.makeVMView(virtualMachine: virtualMachine)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Jeballto VM: \(vmName)"
    window.contentView = vmView
    window.contentMinSize = NSSize(width: 640, height: 480)
    window.center()
    window.isReleasedWhenClosed = false

    let windowDelegate = GUIWindowDelegate(vmId: vmId, guiManager: self)
    window.delegate = windowDelegate

    windows[vmId] = window
    vmViews[vmId] = vmView
    windowDelegates[vmId] = windowDelegate

    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(vmView)
    NSApp.activate(ignoringOtherApps: true)

    eventBus.publish(.guiOpened(vmId: vmId))
    logInfo("GUI opened for VM \(vmId) (\(vmName))", category: "GUIManager")
  }

  func closeGUI(vmId: UUID) {
    guard let window = windows[vmId] else {
      logDebug("No GUI window open for VM \(vmId)", category: "GUIManager")
      return
    }

    window.delegate = nil
    completeGUIClose(vmId: vmId, message: "GUI closed for VM \(vmId)")
    window.close()
  }

  func isGUIOpen(vmId: UUID) -> Bool { windows[vmId] != nil }

  func closeAllGUIs() {
    let vmIds = Array(windows.keys)
    for vmId in vmIds {
      closeGUI(vmId: vmId)
    }
    let hiddenVmIds = Array(hiddenWindows.keys)
    for vmId in hiddenVmIds {
      removeHiddenView(vmId: vmId)
    }
    logInfo("All GUI windows closed", category: "GUIManager")
  }

  func waitForEventProcessing() async {
    await eventProcessor.waitUntilIdle()
  }

  // MARK: - Screenshot Capture

  /// Captures a screenshot of the VM's display as PNG data.
  /// Reuses an existing visible or hidden VZVirtualMachineView, creating a hidden view if needed.
  func captureScreenshot(vmId: UUID, virtualMachine: VZVirtualMachine) throws -> Data {
    let vmView: VZVirtualMachineView = if let existing = vmViews[vmId] {
      existing
    } else {
      ensureHiddenView(vmId: vmId, virtualMachine: virtualMachine)
    }

    let bounds = vmView.bounds
    guard bounds.width > 0, bounds.height > 0 else {
      throw GUIError.screenshotFailed("VM view has zero dimensions")
    }

    guard let bitmapRep = vmView.bitmapImageRepForCachingDisplay(in: bounds) else {
      throw GUIError.screenshotFailed("Failed to create bitmap representation")
    }

    vmView.cacheDisplay(in: bounds, to: bitmapRep)

    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
      throw GUIError.screenshotFailed("Failed to encode screenshot as PNG")
    }

    logInfo("Screenshot captured for VM \(vmId) (\(Int(bounds.width))x\(Int(bounds.height)))", category: "GUIManager")
    return pngData
  }

  // MARK: - Keystroke Injection Support

  func getVMView(_ vmId: UUID) -> VZVirtualMachineView? {
    vmViews[vmId] ?? hiddenViews[vmId]
  }

  func ensureHiddenView(vmId: UUID, virtualMachine: VZVirtualMachine) -> VZVirtualMachineView {
    if let existing = hiddenViews[vmId] { return existing }

    let vmView = Self.makeVMView(virtualMachine: virtualMachine)
    hostHiddenView(vmView, vmId: vmId)
    logInfo("Created hidden view for keystroke injection on VM \(vmId)", category: "GUIManager")
    return vmView
  }

  func acquireKeystrokeView(vmId: UUID, virtualMachine: VZVirtualMachine) -> VZVirtualMachineView {
    let existingView = getVMView(vmId)
    let vmView = existingView ?? ensureHiddenView(vmId: vmId, virtualMachine: virtualMachine)
    activeKeystrokeUsers[vmId, default: 0] += 1
    if existingView == nil {
      removeHiddenViewWhenUnused.insert(vmId)
    }
    return vmView
  }

  func releaseKeystrokeView(vmId: UUID) {
    guard let count = activeKeystrokeUsers[vmId] else { return }
    if count > 1 {
      activeKeystrokeUsers[vmId] = count - 1
      return
    }

    activeKeystrokeUsers.removeValue(forKey: vmId)
    guard removeHiddenViewWhenUnused.remove(vmId) != nil else { return }
    if windows[vmId] == nil {
      removeHiddenViewNow(vmId: vmId)
    }
  }

  func removeHiddenView(vmId: UUID) {
    guard activeKeystrokeUsers[vmId] == nil else {
      removeHiddenViewWhenUnused.insert(vmId)
      return
    }
    removeHiddenViewNow(vmId: vmId)
  }

  private func removeHiddenViewNow(vmId: UUID) {
    guard let window = hiddenWindows.removeValue(forKey: vmId) else { return }
    hiddenViews[vmId]?.virtualMachine = nil
    window.close()
    hiddenViews.removeValue(forKey: vmId)
    removeHiddenViewWhenUnused.remove(vmId)
    logInfo("Removed hidden view for VM \(vmId)", category: "GUIManager")
  }

  // MARK: - Private

  private func activateAppIfNeeded() {
    guard !appActivated else { return }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    // Let the system load the bundle icon with automatic dark/light switching
    app.applicationIconImage = nil
    app.activate(ignoringOtherApps: true)

    appActivated = true
    logInfo("NSApplication activated with .regular policy", category: "GUIManager")
  }

  private func restoreAccessoryPolicyIfNeeded() {
    guard windows.isEmpty, appActivated else { return }
    NSApplication.shared.setActivationPolicy(.accessory)
    appActivated = false
    logInfo("NSApplication restored to .accessory policy", category: "GUIManager")
  }

  private func completeGUIClose(vmId: UUID, message: String) {
    guard windows.removeValue(forKey: vmId) != nil else { return }
    if let vmView = vmViews.removeValue(forKey: vmId) {
      if activeKeystrokeUsers[vmId] != nil {
        vmView.removeFromSuperview()
        hostHiddenView(vmView, vmId: vmId)
        removeHiddenViewWhenUnused.insert(vmId)
      } else {
        vmView.virtualMachine = nil
      }
    }
    windowDelegates.removeValue(forKey: vmId)
    eventBus.publish(.guiClosed(vmId: vmId))
    logInfo(message, category: "GUIManager")
    restoreAccessoryPolicyIfNeeded()
  }

  private static func makeVMView(virtualMachine: VZVirtualMachine) -> VZVirtualMachineView {
    let vmView = VZVirtualMachineView()
    vmView.capturesSystemKeys = true
    // Frame must be set before assigning VM to avoid "display dimensions aren't positive" errors.
    vmView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    vmView.virtualMachine = virtualMachine
    return vmView
  }

  private func hostHiddenView(_ vmView: VZVirtualMachineView, vmId: UUID) {
    if let existingWindow = hiddenWindows.removeValue(forKey: vmId) {
      hiddenViews[vmId]?.virtualMachine = nil
      existingWindow.close()
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = vmView
    window.isReleasedWhenClosed = false
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderBack(nil)
    window.makeFirstResponder(vmView)
    hiddenWindows[vmId] = window
    hiddenViews[vmId] = vmView
  }

  private func takeHiddenView(vmId: UUID) -> VZVirtualMachineView? {
    guard let vmView = hiddenViews.removeValue(forKey: vmId) else { return nil }
    if let window = hiddenWindows.removeValue(forKey: vmId) {
      window.contentView = nil
      window.close()
    }
    return vmView
  }

  private func handleEvent(_ event: VMEvent) {
    switch event {
    case .vmStopped(let vmId), .vmDeleted(let vmId, _):
      if windows[vmId] != nil {
        logInfo("Auto-closing GUI for VM \(vmId) due to \(event.eventType)", category: "GUIManager")
        closeGUI(vmId: vmId)
      }
      removeHiddenView(vmId: vmId)
    case .errorOccurred(let vmId, _):
      guard let vmId else { return }
      if windows[vmId] != nil {
        logInfo("Auto-closing GUI for VM \(vmId) due to error", category: "GUIManager")
        closeGUI(vmId: vmId)
      }
      removeHiddenView(vmId: vmId)
    default:
      break
    }
  }

  // Window close button cleanup  - does NOT call window.close() since the window is already closing
  fileprivate func windowWillClose(vmId: UUID) {
    completeGUIClose(vmId: vmId, message: "GUI window closed by user for VM \(vmId)")
  }
}

/// Closing the window does not stop the VM
@MainActor final class GUIWindowDelegate: NSObject, NSWindowDelegate {
  private let vmId: UUID
  private weak var guiManager: GUIManager?

  init(vmId: UUID, guiManager: GUIManager) {
    self.vmId = vmId
    self.guiManager = guiManager
    super.init()
  }

  func windowWillClose(_ notification: Notification) {
    guiManager?.windowWillClose(vmId: vmId)
  }
}
