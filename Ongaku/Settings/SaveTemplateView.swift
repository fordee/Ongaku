//
//  SaveTemplateView.swift
//  Ongaku
//

import OngakuCore
import SwiftUI

/// File › Save as Template…: names the template made from this song's setup.
struct SaveTemplateView: View {
  let model: ProjectWindowModel
  @State private var name = ""
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let exists = TemplateList.shared.names.contains(ProjectTemplates.cleaned(name))
    VStack(alignment: .leading, spacing: 12) {
      Text("Save as Template").font(.headline)
      Text("A template keeps this song’s tracks, instruments, plug-ins, mixer, tempo and key, but none of its regions or recordings. Start a song from it with File › New from Template.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      TextField("Template name", text: $name)
        .textFieldStyle(.roundedBorder)
        .onSubmit(save)
      if exists {
        Text("A template called “\(ProjectTemplates.cleaned(name))” will be replaced.").font(.callout).foregroundStyle(.orange)
      }
      if let error {
        Text(error).font(.callout).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(ProjectTemplates.cleaned(name).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 400)
    .onAppear { name = model.exportFileName }
  }

  private func save() {
    do {
      try TemplateList.shared.save(model.projectWithCurrentPluginStates(), as: name)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}
