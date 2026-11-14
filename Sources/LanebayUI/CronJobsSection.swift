import LanebayCore
import LanebayDesign
import SwiftUI

/// "Planlagte meldinger": send a message to a card at set times, also when nobody watches the board.
struct CronJobsSection: View {
  @Bindable var model: BoardViewModel
  @State private var adding = false
  @State private var name = ""
  @State private var card = ""
  @State private var when = "07:30"
  @State private var text = ""
  @State private var error: String?

  private var cardTitles: [String] {
    (model.workspace?.nodes ?? []).filter { $0.kind == .console }.map(\.title)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Planlagte meldinger").font(.headline)
          Text("Lanebay starter kortet og sender meldingen til fast tid – svaret havner i chatten. Appen må være åpen.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(adding ? "Lukk" : "Ny") { adding.toggle(); if card.isEmpty { card = cardTitles.first ?? "" } }
          .accessibilityIdentifier("cron.new")
      }
      if adding { editor }
      ForEach(model.cronJobs) { job in row(job) }
      if model.cronJobs.isEmpty && !adding {
        Text("Ingen planlagte meldinger ennå. I terminalen: lanebay cron add Utvikler --when 07:30 --text \"Kjør testene\"")
          .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }
    .padding(16)
    .pastelGlass(radius: 18, tint: DS.Pastel.mint, tintOpacity: 0.12)
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Navn (valgfritt)", text: $name).textFieldStyle(.roundedBorder)
      Picker("Kort", selection: $card) {
        ForEach(cardTitles, id: \.self) { Text($0).tag($0) }
      }
      TextField("Når: 30m, 2t, 07:30 eller hverdager 08:00", text: $when).textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("cron.when")
      if let schedule = CronPlanner.parse(when) {
        Text(CronPlanner.describe(schedule).capitalizedFirst).font(.caption).foregroundStyle(DS.Pastel.mintInk)
      }
      TextField("Melding til kortet", text: $text, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("cron.text")
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Legg til") {
          guard let schedule = CronPlanner.parse(when) else { error = "Ugyldig tidsplan"; return }
          switch model.addCronJob(name: name, card: card, prompt: text, schedule: schedule) {
          case .success: error = nil; adding = false; name = ""; text = ""
          case let .failure(failure): error = failure.message
          }
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("cron.add")
      }
    }
  }

  private func row(_ job: CronJob) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "alarm").foregroundStyle(DS.Pastel.mintInk)
      VStack(alignment: .leading, spacing: 2) {
        Text(job.name).font(.body.weight(.medium))
        Text("\(CronPlanner.describe(job.schedule).capitalizedFirst) → \(job.card)").font(.caption)
        Text(job.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        if let result = job.lastResult, let last = job.lastRun {
          Text("Sist: \(last.formatted(date: .omitted, time: .shortened)) – \(result)")
            .font(.caption2).foregroundStyle(.secondary)
        }
        if !job.history.isEmpty {
          DisclosureGroup("Sendeforsøk (\(job.history.count))") {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(job.history.indices, id: \.self) { index in
                let run = job.history[index]
                Text("\(run.date.formatted(date: .abbreviated, time: .standard)) – \(run.result)")
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
            .textSelection(.enabled)
          }
          .font(.caption2).foregroundStyle(.secondary)
          .accessibilityIdentifier("cron.history.\(job.id)")
        }
      }
      Spacer()
      Toggle("", isOn: Binding(get: { job.enabled }, set: { model.setCronJobEnabled(job.id, $0) }))
        .labelsHidden().toggleStyle(.switch).controlSize(.small)
      Menu {
        Button("Kjør nå") { model.runCronJob(job.id) }
        Button("Slett", role: .destructive) { model.removeCronJob(job.id) }
      } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
    }
    .padding(10)
    .pastelFill(Color.primary, radius: 12, opacity: 0.04)
  }
}

extension String {
  var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
