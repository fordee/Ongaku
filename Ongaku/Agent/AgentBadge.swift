//
//  AgentBadge.swift
//  Ongaku
//

import SwiftUI

/// The control bar's sign that an AI agent is connected: its name beside the LCD, glowing
/// while it works. Hidden when no agent is connected.
struct AgentStatusBadge: View {
  private let server = AgentServer.shared

  var body: some View {
    if !server.clients.isEmpty {
      // The name when there's room; just the sparkles in a narrow window.
      ViewThatFits(in: .horizontal) {
        AgentBadge(names: server.clients, isWorking: server.callsInProgress > 0, lastAction: server.lastAction)
        AgentBadge(names: server.clients, isWorking: server.callsInProgress > 0, lastAction: server.lastAction, isCompact: true)
      }
      .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
  }
}

struct AgentBadge: View {
  let names: [String]
  let isWorking: Bool
  let lastAction: (title: String, succeeded: Bool, date: Date)?
  /// Only the sparkles, for a narrow window (the name is in the tooltip).
  var isCompact = false

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "sparkles")
        .symbolEffect(.variableColor.iterative, isActive: isWorking)
        .accessibilityHidden(true)
      if !isCompact {
        Text(label)
          .lineLimit(1)
          .fixedSize()
      }
    }
    .font(.system(size: 11, weight: .medium))
    .foregroundStyle(Theme.agent)
    .padding(.horizontal, isCompact ? 5 : 9)
    .frame(height: 22)
    .background(Capsule().fill(Theme.agent.opacity(isWorking ? 0.24 : 0.12)))
    .overlay(Capsule().strokeBorder(Theme.agent.opacity(isWorking ? 0.8 : 0.35), lineWidth: 1))
    .shadow(color: Theme.agent.opacity(isWorking ? 0.6 : 0), radius: isWorking ? 7 : 0)
    .animation(.easeInOut(duration: 0.35), value: isWorking)
    .help(tooltip)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(isWorking ? "\(label), working" : "\(label), connected")
    .accessibilityValue(lastActionText ?? "")
    .accessibilityIdentifier("agent-badge")
  }

  /// "Claude Code", or "2 Agents".
  private var label: String {
    names.count == 1 ? names[0] : "\(names.count) Agents"
  }

  private var lastActionText: String? {
    guard let lastAction else { return nil }
    let when = lastAction.date.formatted(.relative(presentation: .named))
    return lastAction.succeeded ? "Last: \(lastAction.title), \(when)" : "Last: \(lastAction.title) (didn't work), \(when)"
  }

  private var tooltip: String {
    let who = names.formatted(.list(type: .and))
    let state = isWorking ? "\(who) \(names.count == 1 ? "is" : "are") working in this song." : "\(who) \(names.count == 1 ? "is" : "are") connected."
    return [state, lastActionText, "Each change can be undone. Settings › Agents has more."].compactMap { $0 }.joined(separator: "\n")
  }
}

#Preview("Badge") {
  VStack(spacing: 16) {
    AgentBadge(names: ["Claude Code"], isWorking: false, lastAction: ("Add Drummer", true, .now.addingTimeInterval(-90)))
    AgentBadge(names: ["Claude Code"], isWorking: true, lastAction: nil)
    AgentBadge(names: ["Claude Code", "Claude Desktop"], isWorking: false, lastAction: nil)
  }
  .padding(30)
  .background(LinearGradient(colors: [Theme.controlBarTop, Theme.controlBarBottom], startPoint: .top, endPoint: .bottom))
  .preferredColorScheme(.dark)
}

#Preview("Control bar") {
  AgentServer.shared.showForPreview(["Claude Code"], working: true)
  return VStack(spacing: 0) {
    ControlBar(model: ProjectWindowModel(document: OngakuDocument(project: .previewSong))).frame(width: 1440)
    ControlBar(model: ProjectWindowModel(document: OngakuDocument(project: .previewSong))).frame(width: 1100)
    ControlBar(model: ProjectWindowModel(document: OngakuDocument(project: .previewSong))).frame(width: 980)
  }
  .preferredColorScheme(.dark)
}
