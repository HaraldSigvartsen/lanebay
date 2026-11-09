import Foundation
import LanebayCore

/// Scheduled messages ("cron"): at the planned time Lanebay starts the card if needed and sends the
/// message through the chat, so the reply lands in the chat even when nobody is looking at the board.
extension BoardViewModel {
  public var cronJobs: [CronJob] { workspace?.cronJobs ?? [] }

  /// Starts the once-every-20-seconds check. Safe to call more than once.
  public func startCronScheduler(interval: Duration = .seconds(20)) {
    guard cronTask == nil else { return }
    cronReference = Date()
    cronTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard let self, !Task.isCancelled else { return }
        self.runDueCronJobs(now: Date())
      }
    }
  }

  public func runDueCronJobs(now: Date) {
    for job in cronJobs where CronPlanner.isDue(job, now: now, reference: cronReference) {
      runCronJob(job.id, now: now)
    }
  }

  @discardableResult
  public func addCronJob(name: String, card: String, prompt: String, schedule: CronSchedule) -> Result<CronJob, CronControlError> {
    let cleanCard = card.trimmingCharacters(in: .whitespacesAndNewlines)
    let job = CronJob(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Jobb" : name,
      card: cleanCard, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), schedule: schedule)
    if let error = CronPlanner.validate(job) { return .failure(CronControlError(error)) }
    guard resolveCard(cleanCard) != nil else { return .failure(CronControlError("Fant ikke kortet «\(cleanCard)».")) }
    editWorkspace { $0.cronJobs.append(job) }
    return .success(job)
  }

  public func removeCronJob(_ id: UUID) { editWorkspace { $0.cronJobs.removeAll { $0.id == id } } }

  public func setCronJobEnabled(_ id: UUID, _ enabled: Bool) {
    editCronJob(id) { $0.enabled = enabled }
  }

  /// Runs a job now (also used by "Kjør nå" and `lanebay cron run`).
  public func runCronJob(_ id: UUID, now: Date = Date()) {
    guard let job = cronJobs.first(where: { $0.id == id }) else { return }
    guard let card = resolveCard(job.card) else {
      editCronJob(id) { $0.lastRun = now; $0.lastResult = "Fant ikke kortet «\(job.card)»" }
      return
    }
    appendChat(ChatEntry(kind: .system, text: "⏰ Planlagt jobb «\(job.name)» (\(CronPlanner.describe(job.schedule)))"))
    let sent = sendChat("@\(handle(for: card)) \(job.prompt)")
    let title = workspace?.nodes.first { $0.id == card }?.title ?? job.card
    editCronJob(id) { $0.lastRun = now; $0.lastResult = sent ? "Sendt til \(title)" : "Kunne ikke sende" }
  }

  private func editCronJob(_ id: UUID, _ change: (inout CronJob) -> Void) {
    editWorkspace { ws in
      if let index = ws.cronJobs.firstIndex(where: { $0.id == id }) { change(&ws.cronJobs[index]) }
    }
  }

  private func cronJob(_ reference: String) -> CronJob? {
    let lower = reference.lowercased()
    return cronJobs.first { $0.id.uuidString.lowercased().hasPrefix(lower) || $0.name.lowercased() == lower }
  }

  public func controlCron(_ args: [String: String]) -> Result<String, CronControlError> {
    switch args["action"] ?? "list" {
    case "add":
      guard let schedule = CronPlanner.parse(args["when"] ?? "") else {
        return .failure(CronControlError("Ugyldig tidsplan. Bruk f.eks. 30m, 2t, 07:30 eller «hverdager 08:00»."))
      }
      return addCronJob(name: args["name"] ?? "Jobb", card: args["card"] ?? "", prompt: args["text"] ?? "", schedule: schedule)
        .map { "La til \($0.id.uuidString.prefix(8)) – \(CronPlanner.describe($0.schedule)) → \($0.card)" }
    case "list":
      let lines = cronJobs.map { job in
        "\(job.id.uuidString.prefix(8))  \(job.enabled ? "på " : "av ")  \(job.name)  \(CronPlanner.describe(job.schedule)) → \(job.card)"
          + (job.lastResult.map { "  (sist: \($0))" } ?? "")
      }
      return .success(lines.isEmpty ? "Ingen planlagte jobber." : lines.joined(separator: "\n"))
    case "rm", "run", "on", "off":
      guard let job = cronJob(args["id"] ?? "") else { return .failure(CronControlError("Fant ikke jobben «\(args["id"] ?? "")».")) }
      switch args["action"] {
      case "rm": removeCronJob(job.id); return .success("Fjernet.")
      case "run": runCronJob(job.id); return .success("Kjører «\(job.name)» nå.")
      case "on": setCronJobEnabled(job.id, true); return .success("Slått på.")
      default: setCronJobEnabled(job.id, false); return .success("Slått av.")
      }
    default:
      return .failure(CronControlError("cron tar add, list, rm, run, on eller off."))
    }
  }
}
