//
//  AgentAreaTests.swift
//  OngakuCoreTests
//

import Testing

@testable import OngakuCore

struct AgentAreaTests {
  @Test func everyAreaNamesRealToolsAndFewOfThem() {
    for area in AgentArea.allCases {
      for name in AgentArea.sharedToolNames + area.toolNames {
        #expect(AgentToolbox.tool(named: name) != nil, "\(area): \(name)")
      }
      #expect(area.toolNames.count <= 8, "\(area)")
      #expect(Set(area.toolNames).count == area.toolNames.count, "\(area) repeats a tool")
      #expect(area.tools.count == AgentArea.sharedToolNames.count + area.toolNames.count)
    }
  }

  @Test func everyToolIsInSomeArea() {
    let covered = Set(AgentArea.sharedToolNames + AgentArea.allCases.flatMap(\.toolNames))
    let missing = AgentToolbox.tools.map(\.name).filter { !covered.contains($0) }
    #expect(missing.isEmpty, "Not in any area: \(missing)")
  }

  @Test func compactInstructionsUseThePitchNaming() {
    #expect(AgentToolbox.compactInstructions(pitchNaming: .logic).contains("C3"))
    #expect(AgentToolbox.compactInstructions(pitchNaming: .scientific).contains("C4"))
    // About 200 tokens: the tools' definitions need the rest of the context.
    #expect(AgentToolbox.compactInstructions().count < 900)
  }
}
