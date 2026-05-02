import Cocoa
import Virtualization

enum GUIError: Error, LocalizedError {
  case vmNotRunning(UUID)
  case vmNotFound(UUID)
  case windowCreationFailed(String)
  case screenshotFailed(String)

  var errorDescription: String? {
    switch self {
    case .vmNotRunning(let id): "VM \(id.uuidString) is not running"
    case .vmNotFound(let id): "VM \(id.uuidString) not found"
    case .windowCreationFailed(let message): "Failed to create window: \(message)"
    case .screenshotFailed(let message): "Screenshot failed: \(message)"
    }
  }
}

@MainActor class GUIManager {
  private var windows: [UUID: NSWindow] = [:]
  private var vmViews: [UUID: VZVirtualMachineView] = [:]
  // Strong refs needed because NSWindow.delegate is weak
  private var windowDelegates: [UUID: GUIWindowDelegate] = [:]
  private var hiddenWindows: [UUID: NSWindow] = [:]
  private var hiddenViews: [UUID: VZVirtualMachineView] = [:]
  private var appActivated = false
  private let eventBus: EventBus
  private var eventSubscription: EventBus.SubscriptionToken?

  init(eventBus: EventBus) {
    self.eventBus = eventBus

    eventSubscription = eventBus.subscribe { [weak self] event in
      guard let self else { return }
      Task { @MainActor in self.handleEvent(event) }
    }
  }

  deinit { if let token = eventSubscription { eventBus.unsubscribe(token) } }

  // MARK: - Public API

  func openGUI(vmId: UUID, virtualMachine: VZVirtualMachine, vmName: String) {
    if let existingWindow = windows[vmId] {
      existingWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      logInfo("GUI already open for VM \(vmId), brought to front", category: "GUIManager")
      return
    }

    activateAppIfNeeded()

    let vmView = VZVirtualMachineView()
    vmView.capturesSystemKeys = true
    // Frame must be set before assigning VM to avoid "display dimensions aren't positive" errors
    vmView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    vmView.virtualMachine = virtualMachine

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

    vmViews[vmId]?.virtualMachine = nil
    window.close()
    windows.removeValue(forKey: vmId)
    vmViews.removeValue(forKey: vmId)
    windowDelegates.removeValue(forKey: vmId)

    eventBus.publish(.guiClosed(vmId: vmId))
    logInfo("GUI closed for VM \(vmId)", category: "GUIManager")
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

    activateAppIfNeeded()

    let vmView = VZVirtualMachineView()
    vmView.capturesSystemKeys = true
    vmView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    vmView.virtualMachine = virtualMachine

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

    logInfo("Created hidden view for keystroke injection on VM \(vmId)", category: "GUIManager")
    return vmView
  }

  func removeHiddenView(vmId: UUID) {
    guard let window = hiddenWindows[vmId] else { return }
    hiddenViews[vmId]?.virtualMachine = nil
    window.close()
    hiddenWindows.removeValue(forKey: vmId)
    hiddenViews.removeValue(forKey: vmId)
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

  private func handleEvent(_ event: VMEvent) {
    switch event {
    case .vmStopped(let vmId), .vmDeleted(let vmId, _):
      if windows[vmId] != nil {
        logInfo("Auto-closing GUI for VM \(vmId) due to \(event.eventType)", category: "GUIManager")
        closeGUI(vmId: vmId)
      }
      removeHiddenView(vmId: vmId)
    case .errorOccurred(let vmId, _):
      if let vmId, windows[vmId] != nil {
        logInfo("Auto-closing GUI for VM \(vmId) due to error", category: "GUIManager")
        closeGUI(vmId: vmId)
      }
    default:
      break
    }
  }

  // Window close button cleanup  - does NOT call window.close() since the window is already closing
  fileprivate func windowWillClose(vmId: UUID) {
    vmViews[vmId]?.virtualMachine = nil
    windows.removeValue(forKey: vmId)
    vmViews.removeValue(forKey: vmId)
    windowDelegates.removeValue(forKey: vmId)

    eventBus.publish(.guiClosed(vmId: vmId))
    logInfo("GUI window closed by user for VM \(vmId)", category: "GUIManager")
  }
}

/// Closing the window does not stop the VM
@MainActor class GUIWindowDelegate: NSObject, NSWindowDelegate {
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
