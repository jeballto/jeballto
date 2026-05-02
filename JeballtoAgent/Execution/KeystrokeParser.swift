import Cocoa

enum KeystrokeAction {
  case keyPress(keyCode: UInt16, characters: String)
  case modifierChange(flags: NSEvent.ModifierFlags, keyCode: UInt16, keyDown: Bool)
  case wait(TimeInterval)
}

enum KeystrokeParserError: Error, LocalizedError {
  case unknownToken(String)
  case invalidWaitDuration(String)
  case tooManyActions(Int)
  case waitDurationTooLong(TimeInterval)

  var errorDescription: String? {
    switch self {
    case .unknownToken(let token): "Unknown keystroke token: <\(token)>"
    case .invalidWaitDuration(let value): "Invalid wait duration: \(value)"
    case .tooManyActions(let count): "Too many keystroke actions (\(count), max \(KeystrokeParser.maxActions))"
    case .waitDurationTooLong(let duration):
      "Wait duration too long (\(duration)s, max \(KeystrokeParser.maxWaitDuration)s)"
    }
  }
}

enum KeystrokeParser {
  /// Maximum number of actions from a single parse call
  static let maxActions = 10000

  /// Maximum allowed wait duration in a single <waitNs> token
  static let maxWaitDuration: TimeInterval = 300

  // MARK: - Parsing

  static func parse(_ input: String) throws -> [KeystrokeAction] {
    var actions: [KeystrokeAction] = []
    var index = input.startIndex

    while index < input.endIndex {
      if input[index] == "<" {
        if let closeIndex = input[index...].firstIndex(of: ">") {
          let tokenStart = input.index(after: index)
          let token = String(input[tokenStart ..< closeIndex])
          let action = try parseToken(token)
          actions.append(contentsOf: action)
          index = input.index(after: closeIndex)
        } else {
          actions.append(contentsOf: charAction(input[index]))
          index = input.index(after: index)
        }
      } else {
        actions.append(contentsOf: charAction(input[index]))
        index = input.index(after: index)
      }

      if actions.count > maxActions {
        throw KeystrokeParserError.tooManyActions(actions.count)
      }
    }

    return actions
  }

  private static func parseToken(_ token: String) throws -> [KeystrokeAction] {
    let lower = token.lowercased()

    if let keyCode = specialKeys[lower] {
      let chars = specialKeyChars[lower] ?? ""
      return [.keyPress(keyCode: keyCode, characters: chars)]
    }

    if lower.hasSuffix("on") {
      let prefix = String(lower.dropLast(2))
      if let flags = modifierFlag(for: prefix), let keyCode = modifierKeyCode(for: prefix) {
        return [.modifierChange(flags: flags, keyCode: keyCode, keyDown: true)]
      }
    }
    if lower.hasSuffix("off") {
      let prefix = String(lower.dropLast(3))
      if let flags = modifierFlag(for: prefix), let keyCode = modifierKeyCode(for: prefix) {
        return [.modifierChange(flags: flags, keyCode: keyCode, keyDown: false)]
      }
    }

    if lower.hasPrefix("wait") {
      guard let duration = parseWaitDuration(lower) else {
        throw KeystrokeParserError.invalidWaitDuration(String(lower.dropFirst(4)))
      }
      guard duration > 0, duration <= maxWaitDuration else {
        throw duration <= 0
          ? KeystrokeParserError.invalidWaitDuration(String(lower.dropFirst(4)))
          : KeystrokeParserError.waitDurationTooLong(duration)
      }
      return [.wait(duration)]
    }

    throw KeystrokeParserError.unknownToken(token)
  }

  private static func parseWaitDuration(_ token: String) -> TimeInterval? {
    guard token.hasPrefix("wait") else { return nil }
    let value = String(token.dropFirst(4))
    if value.hasSuffix("s"), let seconds = Double(value.dropLast()) {
      return seconds
    }
    if let seconds = Double(value) {
      return seconds
    }
    return nil
  }

  private static func modifierFlag(for prefix: String) -> NSEvent.ModifierFlags? {
    let base: NSEvent.ModifierFlags?
    switch prefix {
    case "leftshift", "rightshift": base = .shift
    case "leftctrl", "rightctrl": base = .control
    case "leftalt", "rightalt": base = .option
    case "leftcmd", "rightcmd": base = .command
    default: return nil
    }
    guard let base else { return nil }
    return base.union(NSEvent.ModifierFlags(rawValue: deviceDependentFlags(for: prefix)))
  }

  private static func deviceDependentFlags(for prefix: String) -> UInt {
    switch prefix {
    case "leftshift": 0x000002 // NX_DEVICELSHIFTKEYMASK
    case "rightshift": 0x000004 // NX_DEVICERSHIFTKEYMASK
    case "leftctrl": 0x000001 // NX_DEVICELCTLKEYMASK
    case "rightctrl": 0x002000 // NX_DEVICERCTLKEYMASK
    case "leftalt": 0x000020 // NX_DEVICELALTKEYMASK
    case "rightalt": 0x000040 // NX_DEVICERALTKEYMASK
    case "leftcmd": 0x000008 // NX_DEVICELCMDKEYMASK
    case "rightcmd": 0x000010 // NX_DEVICERCMDKEYMASK
    default: 0
    }
  }

  private static func modifierKeyCode(for prefix: String) -> UInt16? {
    switch prefix {
    case "leftshift": 0x38
    case "rightshift": 0x3C
    case "leftctrl": 0x3B
    case "rightctrl": 0x3E
    case "leftalt": 0x3A
    case "rightalt": 0x3D
    case "leftcmd": 0x37
    case "rightcmd": 0x36
    default: nil
    }
  }

  private static func charAction(_ char: Character) -> [KeystrokeAction] {
    let str = String(char)

    // Check if this is a shifted symbol (e.g. &, !, @, #)
    if let (keyCode, _) = shiftedSymbols[char] {
      let shiftFlags = NSEvent.ModifierFlags.shift
        .union(NSEvent.ModifierFlags(rawValue: 0x000002))
      return [
        .modifierChange(flags: shiftFlags, keyCode: 0x38, keyDown: true),
        .keyPress(keyCode: keyCode, characters: str),
        .modifierChange(flags: shiftFlags, keyCode: 0x38, keyDown: false),
      ]
    }

    let isUpper = char.isUppercase
    let lookupChar = isUpper ? Character(char.lowercased()) : char
    let keyCode = charToKeyCode[lookupChar] ?? 0

    if isUpper {
      let shiftFlags = NSEvent.ModifierFlags.shift
        .union(NSEvent.ModifierFlags(rawValue: 0x000002))
      return [
        .modifierChange(flags: shiftFlags, keyCode: 0x38, keyDown: true),
        .keyPress(keyCode: keyCode, characters: str),
        .modifierChange(flags: shiftFlags, keyCode: 0x38, keyDown: false),
      ]
    }
    return [.keyPress(keyCode: keyCode, characters: str)]
  }

  /// Maps shifted symbols to their (keyCode, unshifted character) on US keyboard layout
  static let shiftedSymbols: [Character: (UInt16, Character)] = [
    "!": (0x12, "1"),
    "@": (0x13, "2"),
    "#": (0x14, "3"),
    "$": (0x15, "4"),
    "%": (0x17, "5"),
    "^": (0x16, "6"),
    "&": (0x1A, "7"),
    "*": (0x1C, "8"),
    "(": (0x19, "9"),
    ")": (0x1D, "0"),
    "_": (0x1B, "-"),
    "+": (0x18, "="),
    "{": (0x21, "["),
    "}": (0x1E, "]"),
    "|": (0x2A, "\\"),
    ":": (0x29, ";"),
    "\"": (0x27, "'"),
    "<": (0x2B, ","),
    ">": (0x2F, "."),
    "?": (0x2C, "/"),
    "~": (0x32, "`"),
  ]

  // MARK: - Key Code Maps

  static let specialKeys: [String: UInt16] = [
    "enter": 0x24,
    "return": 0x24,
    "tab": 0x30,
    "spacebar": 0x31,
    "space": 0x31,
    "delete": 0x33,
    "backspace": 0x33,
    "esc": 0x35,
    "escape": 0x35,
    "left": 0x7B,
    "right": 0x7C,
    "down": 0x7D,
    "up": 0x7E,
    "f1": 0x7A,
    "f2": 0x78,
    "f3": 0x63,
    "f4": 0x76,
    "f5": 0x60,
    "f6": 0x61,
    "f7": 0x62,
    "f8": 0x64,
    "f9": 0x65,
    "f10": 0x6D,
    "f11": 0x67,
    "f12": 0x6F,
    "home": 0x73,
    "end": 0x77,
    "pageup": 0x74,
    "pagedown": 0x79,
  ]

  static let specialKeyChars: [String: String] = [
    "enter": "\r",
    "return": "\r",
    "tab": "\t",
    "spacebar": " ",
    "space": " ",
    "esc": "\u{1B}",
    "escape": "\u{1B}",
    "delete": "\u{7F}",
    "backspace": "\u{7F}",
  ]

  static let charToKeyCode: [Character: UInt16] = [
    "a": 0x00,
    "s": 0x01,
    "d": 0x02,
    "f": 0x03,
    "h": 0x04,
    "g": 0x05,
    "z": 0x06,
    "x": 0x07,
    "c": 0x08,
    "v": 0x09,
    "b": 0x0B,
    "q": 0x0C,
    "w": 0x0D,
    "e": 0x0E,
    "r": 0x0F,
    "y": 0x10,
    "t": 0x11,
    "1": 0x12,
    "2": 0x13,
    "3": 0x14,
    "4": 0x15,
    "6": 0x16,
    "5": 0x17,
    "=": 0x18,
    "9": 0x19,
    "7": 0x1A,
    "-": 0x1B,
    "8": 0x1C,
    "0": 0x1D,
    "]": 0x1E,
    "o": 0x1F,
    "u": 0x20,
    "[": 0x21,
    "i": 0x22,
    "p": 0x23,
    "l": 0x25,
    "j": 0x26,
    "'": 0x27,
    "k": 0x28,
    ";": 0x29,
    "\\": 0x2A,
    ",": 0x2B,
    "/": 0x2C,
    "n": 0x2D,
    "m": 0x2E,
    ".": 0x2F,
    "`": 0x32,
    " ": 0x31,
  ]
}
