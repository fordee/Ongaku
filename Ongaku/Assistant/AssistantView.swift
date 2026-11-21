//
//  AssistantView.swift
//  Ongaku
//

import FoundationModels
import OngakuCore
import SwiftUI

/// The Assistant panel down the right of the window: ask for something in plain words and
/// the on-device model does it with Ongaku's tools, each change one undo step.
struct AssistantView: View {
  static let width: CGFloat = 300

  let model: ProjectWindowModel
  /// Overrides the Mac's Apple Intelligence status (for previews).
  var unavailableReason: String??

  var body: some View {
    let assistant = model.assistant
    VStack(spacing: 0) {
      PaneHeader(title: "Assistant", symbol: "sparkles", closeTitle: "Hide Assistant") {
        model.isAssistantVisible = false
      } accessory: {
        if !assistant.messages.isEmpty {
          Button("New Conversation", systemImage: "square.and.pencil") { assistant.clear() }
            .buttonStyle(ThemeButtonStyle(width: 22, height: 18))
            .help("Start a new conversation")
        }
      }
      if let reason = unavailableReason ?? assistant.unavailableReason {
        AssistantUnavailable(reason: reason)
      } else {
        AssistantConversation(model: model, assistant: assistant)
        AssistantInput(model: model, assistant: assistant)
      }
    }
    .frame(width: Self.width)
    .background(Theme.panel)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Assistant")
    .accessibilityIdentifier("assistant")
  }
}

private struct AssistantUnavailable: View {
  let reason: String

  var body: some View {
    VStack(spacing: 14) {
      Spacer()
      Image(systemName: "sparkles")
        .font(.system(size: 34))
        .foregroundStyle(Theme.agent)
      Text("The Assistant Isn’t Available")
        .font(Theme.font(14, weight: .semibold))
      Text(reason)
        .font(Theme.font(11))
        .foregroundStyle(Theme.secondaryText)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
    }
    .padding(20)
    .frame(maxWidth: .infinity)
  }
}

private struct AssistantConversation: View {
  let model: ProjectWindowModel
  let assistant: AssistantModel

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if assistant.messages.isEmpty {
            AssistantWelcome(model: model, assistant: assistant)
          }
          ForEach(assistant.messages) { message in
            AssistantBubble(message: message)
              .id(message.id)
          }
          if assistant.isResponding {
            AssistantWorking(action: assistant.currentAction)
              .id("working")
          }
        }
        .padding(10)
      }
      .onChange(of: assistant.messages.count) {
        withAnimation { proxy.scrollTo(assistant.messages.last?.id, anchor: .bottom) }
      }
      .onChange(of: assistant.isResponding) {
        if assistant.isResponding { withAnimation { proxy.scrollTo("working", anchor: .bottom) } }
      }
    }
    .frame(maxHeight: .infinity)
  }
}

/// Before the first request: what it can do, with a few to try.
private struct AssistantWelcome: View {
  let model: ProjectWindowModel
  let assistant: AssistantModel

  static let suggestions = [
    "Set the tempo to 96 and the key to A minor",
    "Lay out Intro, Verse, Chorus, Verse, Chorus, Outro",
    "Add a Drummer to every section",
    "Add a reverb to the selected track",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Ask for something in the song, in plain words. Apple Intelligence does it on this Mac, and you can undo each change.")
        .font(Theme.font(11))
        .foregroundStyle(Theme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(Self.suggestions, id: \.self) { suggestion in
        Button {
          assistant.draft = suggestion
          assistant.send(in: model)
        } label: {
          Label(suggestion, systemImage: "sparkle")
            .font(Theme.font(11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.raised, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
      }
    }
  }
}

private struct AssistantBubble: View {
  let message: AssistantModel.Message

  var body: some View {
    let isPerson = message.role == .person
    VStack(alignment: isPerson ? .trailing : .leading, spacing: 4) {
      Text(message.text)
        .font(Theme.font(12))
        .textSelection(.enabled)
        .foregroundStyle(message.role == .problem ? Theme.secondaryText : Theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isPerson ? Theme.accent.opacity(0.55) : Theme.raised, in: .rect(cornerRadius: 10))
      if !message.actions.isEmpty {
        Label(message.actions.joined(separator: ", "), systemImage: "checkmark.circle")
          .font(Theme.font(10))
          .foregroundStyle(Theme.agent)
          .padding(.horizontal, 4)
          .accessibilityLabel("Changed: \(message.actions.joined(separator: ", "))")
      }
    }
    .frame(maxWidth: .infinity, alignment: isPerson ? .trailing : .leading)
    .padding(isPerson ? .leading : .trailing, 30)
  }
}

private struct AssistantWorking: View {
  let action: String?

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "sparkles")
        .foregroundStyle(Theme.agent)
        .symbolEffect(.pulse)
      Text(action.map { "\($0)…" } ?? "Thinking…")
        .font(Theme.font(11))
        .foregroundStyle(Theme.secondaryText)
    }
    .padding(.horizontal, 4)
  }
}

private struct AssistantInput: View {
  let model: ProjectWindowModel
  @Bindable var assistant: AssistantModel

  var body: some View {
    HStack(spacing: 6) {
      TextField("Ask the Assistant", text: $assistant.draft, axis: .vertical)
        .textFieldStyle(.plain)
        .font(Theme.font(12))
        .lineLimit(1...5)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.window, in: .rect(cornerRadius: 7))
        .onSubmit { assistant.send(in: model) }
        .accessibilityIdentifier("assistant-field")
      if assistant.isResponding {
        Button("Stop", systemImage: "stop.fill") { assistant.stop() }
          .buttonStyle(ThemeButtonStyle(width: 26, height: 24))
          .help("Stop")
      } else {
        Button("Send", systemImage: "arrow.up") { assistant.send(in: model) }
          .buttonStyle(ThemeButtonStyle(isOn: !assistant.draft.isEmpty, onColor: Theme.accent, width: 26, height: 24))
          .disabled(assistant.draft.trimmingCharacters(in: .whitespaces).isEmpty)
          .help("Send (Return)")
      }
    }
    .padding(10)
    .overlay(alignment: .top) {
      Rectangle().fill(Theme.separator).frame(height: 1)
    }
  }
}

#Preview("Assistant") {
  let model = ProjectWindowModel(document: OngakuDocument())
  model.assistant.messages = [
    .init(role: .person, text: "Set the tempo to 96 and lay out a verse and a chorus"),
    .init(role: .assistant, text: "Done: the song is at 96 BPM, with an 8-bar Verse and an 8-bar Chorus.", actions: ["Set Tempo", "Set Arrangement"]),
    .init(role: .person, text: "Add a drummer"),
  ]
  return AssistantView(model: model, unavailableReason: .some(nil))
    .frame(height: 520)
}

#Preview("Assistant Unavailable") {
  AssistantView(
    model: ProjectWindowModel(document: OngakuDocument()),
    unavailableReason: AssistantModel.explanation(of: .unavailable(.appleIntelligenceNotEnabled)))
    .frame(height: 360)
}
