//
//  ProjectWindowModel+Score.swift
//  Ongaku
//

import AppKit
import OngakuCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

extension ProjectWindowModel {
  /// The MIDI region open in the editor, which the score commands print and export.
  var scoreRegion: Region? {
    guard let region = pianoRoll.region, case .midi = region.content else { return nil }
    return region
  }

  private var scoreTitle: String { documentTitle.name }

  private var scorePartName: String {
    guard let region = scoreRegion else { return "" }
    return project.tracks.first { $0.regions.contains { $0.id == region.id } }?.name ?? region.name
  }

  /// File › Print Score…: the open region's score on pages, through the print panel.
  func printScore() {
    guard let region = scoreRegion else { return }
    let data = ScorePDF.data(
      layout: pianoRoll.scoreLayout(for: region), title: scoreTitle, subtitle: scorePartName, pageSize: NSPrintInfo.shared.paperSize)
    guard let document = PDFDocument(data: data),
      let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: false)
    else {
      errorMessage = "The score couldn't be printed."
      return
    }
    operation.jobTitle = "\(scoreTitle) – \(scorePartName)"
    operation.run()
  }

  /// File › Export Score as PDF…
  func exportScorePDF() {
    guard let region = scoreRegion else { return }
    let data = ScorePDF.data(
      layout: pianoRoll.scoreLayout(for: region), title: scoreTitle, subtitle: scorePartName, pageSize: NSPrintInfo.shared.paperSize)
    save(data, as: "\(scorePartName) – \(region.name).pdf", type: .pdf)
  }

  /// File › Export Score as MusicXML…: for notation apps.
  func exportScoreMusicXML() {
    guard let region = scoreRegion else { return }
    let text = MusicXML.document(for: pianoRoll.scoreLayout(for: region), title: scoreTitle, partName: scorePartName)
    save(Data(text.utf8), as: "\(scorePartName) – \(region.name).musicxml", type: .musicXML)
  }

  private func save(_ data: Data, as name: String, type: UTType) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [type]
    panel.nameFieldStringValue = name
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      errorMessage = "“\(url.lastPathComponent)” couldn’t be saved: \(error.localizedDescription)"
    }
  }
}

extension UTType {
  /// MusicXML, uncompressed.
  static let musicXML = UTType(filenameExtension: "musicxml", conformingTo: .xml) ?? .xml
}

/// A score on printed pages: black on white, the title on the first page, systems moved to
/// the next page rather than cut.
enum ScorePDF {
  static let margin: CGFloat = 40

  @MainActor
  static func data(layout: ScoreLayout, title: String, subtitle: String, pageSize: CGSize) -> Data {
    let size = pageSize.width > 0 && pageSize.height > 0 ? pageSize : CGSize(width: 595, height: 842)
    let score = EngravedScore(layout: layout, width: size.width - margin * 2, space: 6.5, margin: 0)
    let titleHeight: CGFloat = 70
    // Which systems go on each page.
    var pages: [(offset: CGFloat, systems: Range<Int>)] = []
    var start = 0
    while start < score.systems.count {
      let available = size.height - margin * 2 - (pages.isEmpty ? titleHeight : 0)
      let top = score.systems[start].top
      var end = start + 1
      while end < score.systems.count, score.systems[end].bottom - top <= available { end += 1 }
      pages.append((top, start..<end))
      start = end
    }
    if pages.isEmpty { pages = [(0, 0..<0)] }

    let output = NSMutableData()
    guard let consumer = CGDataConsumer(data: output) else { return Data() }
    var box = CGRect(origin: .zero, size: size)
    guard let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
    for (index, page) in pages.enumerated() {
      let view = ScorePageView(
        score: score, systems: page.systems, offset: page.offset, title: index == 0 ? title : nil, subtitle: subtitle,
        pageNumber: index + 1, pageCount: pages.count, titleHeight: titleHeight
      )
      .frame(width: size.width, height: size.height)
      let renderer = ImageRenderer(content: view)
      renderer.proposedSize = ProposedViewSize(size)
      pdf.beginPDFPage(nil)
      renderer.render { _, draw in draw(pdf) }
      pdf.endPDFPage()
    }
    pdf.closePDF()
    return output as Data
  }
}

/// One printed page.
private struct ScorePageView: View {
  let score: EngravedScore
  let systems: Range<Int>
  let offset: CGFloat
  let title: String?
  let subtitle: String
  let pageNumber: Int
  let pageCount: Int
  let titleHeight: CGFloat

  var body: some View {
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
      let margin = ScorePDF.margin
      if let title {
        context.draw(Text(title).font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(.black),
          at: CGPoint(x: size.width / 2, y: margin + 10), anchor: .top)
        context.draw(Text(subtitle).font(.system(size: 12, design: .serif)).foregroundStyle(.black),
          at: CGPoint(x: margin, y: margin + titleHeight - 14), anchor: .bottomLeading)
      }
      if pageCount > 1 {
        context.draw(Text("\(pageNumber)").font(.system(size: 10)).foregroundStyle(.black),
          at: CGPoint(x: size.width - margin, y: size.height - margin / 2), anchor: .bottomTrailing)
      }
      var shown = score
      shown.systems = Array(score.systems[systems])
      var page = context
      page.translateBy(x: margin, y: margin + (title != nil ? titleHeight : 0) - offset)
      ScoreRenderer(score: shown, palette: .print, endsScore: systems.upperBound == score.systems.count).draw(in: page)
    }
  }
}

#Preview("Printed Score") {
  // Page 1 of a printed part, as the PDF has it.
  let notes = (0..<96).map { index in
    MIDINote(pitch: [60, 62, 64, 65, 67, 69, 71, 72][index % 8], velocity: 90, start: Tick(480) * Int64(index), length: Tick(index % 5 == 0 ? 960 : 480))
  }
  let region = Region(name: "Etude", start: .zero, length: Tick(3840 * 12), content: .midi(MIDISequence(notes: notes)))
  let data = ScorePDF.data(
    layout: ScoreLayout(region: region, in: Project()), title: "Little Etude", subtitle: "Piano", pageSize: CGSize(width: 595, height: 842))
  let image = PDFDocument(data: data)?.page(at: 0)?.thumbnail(of: NSSize(width: 595, height: 842), for: .mediaBox)
  return Group {
    if let image { Image(nsImage: image) } else { Text("No PDF") }
  }
  .frame(width: 595, height: 842)
}
