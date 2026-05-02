import AppKit
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct KeystrokeParserTests {
  @Test
  func parsesSpecialKeysAndCharacters() throws {
    let actions = try KeystrokeParser.parse("a<enter>")

    #expect(actions.count == 2)

    if case .keyPress(_, let firstChars) = actions[0] {
      #expect(firstChars == "a")
    } else {
      Issue.record("Expected first action to be a key press")
    }

    if case .keyPress(_, let secondChars) = actions[1] {
      #expect(secondChars == "\r")
    } else {
      Issue.record("Expected second action to be Enter key press")
    }
  }

  @Test
  func uppercaseCharacterProducesShiftModifierSequence() throws {
    let actions = try KeystrokeParser.parse("A")

    #expect(actions.count == 3)
    if case .modifierChange(let flags, _, let keyDown) = actions[0] {
      #expect(flags.contains(.shift))
      #expect(keyDown)
    } else {
      Issue.record("Expected shift modifier down")
    }

    if case .modifierChange(let flags, _, let keyDown) = actions[2] {
      #expect(flags.contains(.shift))
      #expect(keyDown == false)
    } else {
      Issue.record("Expected shift modifier up")
    }
  }

  @Test
  func parsesWaitToken() throws {
    let actions = try KeystrokeParser.parse("<wait2.5s>")

    #expect(actions.count == 1)
    if case .wait(let seconds) = actions[0] {
      #expect(seconds == 2.5)
    } else {
      Issue.record("Expected wait action")
    }
  }

  @Test
  func invalidTokenThrows() {
    #expect(throws: KeystrokeParserError.self) {
      _ = try KeystrokeParser.parse("<unknown>")
    }
  }

  @Test
  func tooManyActionsThrows() {
    let input = String(repeating: "a", count: KeystrokeParser.maxActions + 1)

    #expect(throws: KeystrokeParserError.self) {
      _ = try KeystrokeParser.parse(input)
    }
  }

  @Test
  func excessiveWaitDurationThrows() {
    #expect(throws: KeystrokeParserError.self) {
      _ = try KeystrokeParser.parse("<wait301s>")
    }
  }

  @Test(arguments: [
    ("&", UInt16(0x1A)),
    ("!", UInt16(0x12)),
    ("@", UInt16(0x13)),
    ("#", UInt16(0x14)),
    ("$", UInt16(0x15)),
    ("^", UInt16(0x16)),
    ("*", UInt16(0x1C)),
    ("(", UInt16(0x19)),
    (")", UInt16(0x1D)),
    ("_", UInt16(0x1B)),
    ("+", UInt16(0x18)),
    ("{", UInt16(0x21)),
    ("}", UInt16(0x1E)),
    ("|", UInt16(0x2A)),
    (":", UInt16(0x29)),
    ("?", UInt16(0x2C)),
    ("~", UInt16(0x32)),
  ])
  func shiftedSymbolProducesShiftModifierSequence(_ input: (symbol: String, expectedKeyCode: UInt16)) throws {
    let actions = try KeystrokeParser.parse(input.symbol)

    #expect(actions.count == 3, "Expected shift-down, keyPress, shift-up for '\(input.symbol)'")

    if case .modifierChange(let flags, _, let keyDown) = actions[0] {
      #expect(flags.contains(.shift))
      #expect(keyDown)
    } else {
      Issue.record("Expected shift modifier down for '\(input.symbol)'")
    }

    if case .keyPress(let keyCode, let chars) = actions[1] {
      #expect(keyCode == input.expectedKeyCode, "Wrong keyCode for '\(input.symbol)'")
      #expect(chars == input.symbol)
    } else {
      Issue.record("Expected key press for '\(input.symbol)'")
    }

    if case .modifierChange(let flags, _, let keyDown) = actions[2] {
      #expect(flags.contains(.shift))
      #expect(keyDown == false)
    } else {
      Issue.record("Expected shift modifier up for '\(input.symbol)'")
    }
  }
}
