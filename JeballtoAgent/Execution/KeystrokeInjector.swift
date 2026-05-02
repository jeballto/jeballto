import Cocoa
import Virtualization

enum KeystrokeInjectorError: Error, LocalizedError {
  case noVirtualMachine(UUID)
  case eventCreationFailed

  var errorDescription: String? {
    switch self {
    case .noVirtualMachine(let id): "No virtual machine available for VM \(id.uuidString)"
    case .eventCreationFailed: "Failed to create synthetic keyboard event"
    }
  }
}

class KeystrokeInjector {
  private let delayBetweenKeys: TimeInterval = 0.075

  @MainActor func execute(
    actions: [KeystrokeAction],
    vm: VZVirtualMachine,
    vmId: UUID,
    guiManager: GUIManager
  ) async throws -> Int {
    let (vmView, isHidden) = ensureView(vm: vm, vmId: vmId, guiManager: guiManager)

    defer {
      if isHidden {
        guiManager.removeHiddenView(vmId: vmId)
      }
    }

    var activeModifiers: NSEvent.ModifierFlags = []
    var count = 0

    defer {
      if !activeModifiers.isEmpty {
        activeModifiers = []
        try? sendFlagsChanged(modifiers: [], keyCode: 0, view: vmView)
      }
    }

    for action in actions {
      switch action {
      case .keyPress(let keyCode, let characters):
        try sendKeyPress(keyCode: keyCode, characters: characters, modifiers: activeModifiers, view: vmView)
        count += 1
        try await Task.sleep(nanoseconds: UInt64(delayBetweenKeys * 1_000_000_000))

      case .modifierChange(let flags, let keyCode, let keyDown):
        if keyDown {
          activeModifiers.insert(flags)
        } else {
          activeModifiers.remove(flags)
        }
        try sendFlagsChanged(modifiers: activeModifiers, keyCode: keyCode, view: vmView)
        count += 1
        try await Task.sleep(nanoseconds: UInt64(delayBetweenKeys * 1_000_000_000))

      case .wait(let duration):
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      }
    }

    return count
  }

  // MARK: - Private

  @MainActor private func ensureView(
    vm: VZVirtualMachine,
    vmId: UUID,
    guiManager: GUIManager
  ) -> (VZVirtualMachineView, Bool) {
    if let existingView = guiManager.getVMView(vmId) {
      return (existingView, false)
    }
    let view = guiManager.ensureHiddenView(vmId: vmId, virtualMachine: vm)
    return (view, true)
  }

  @MainActor private func sendKeyPress(
    keyCode: UInt16,
    characters: String,
    modifiers: NSEvent.ModifierFlags,
    view: VZVirtualMachineView
  ) throws {
    let charsIgnoringModifiers = characters.lowercased()

    guard let keyDown = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: view.window?.windowNumber ?? 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: charsIgnoringModifiers,
      isARepeat: false,
      keyCode: keyCode
    ) else { throw KeystrokeInjectorError.eventCreationFailed }

    guard let keyUp = NSEvent.keyEvent(
      with: .keyUp,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: view.window?.windowNumber ?? 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: charsIgnoringModifiers,
      isARepeat: false,
      keyCode: keyCode
    ) else { throw KeystrokeInjectorError.eventCreationFailed }

    view.keyDown(with: keyDown)
    view.keyUp(with: keyUp)
  }

  @MainActor private func sendFlagsChanged(
    modifiers: NSEvent.ModifierFlags,
    keyCode: UInt16,
    view: VZVirtualMachineView
  ) throws {
    guard let event = NSEvent.keyEvent(
      with: .flagsChanged,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: view.window?.windowNumber ?? 0,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: keyCode
    ) else { throw KeystrokeInjectorError.eventCreationFailed }

    view.flagsChanged(with: event)
  }
}
