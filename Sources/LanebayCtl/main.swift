import Foundation
import LanebayCore

let usage = """
usage: lanebay <command> [options]

  spawn  --provider <id> --cwd <dir> --task "<short task>" [--timeout 55m] [--context <file>]
  read   <id> [--tail <lines>]
  send   <id> "<text>"
  status [<id>]
  stop   <id>
  list
  link   add <from> <to> [--two-way] [--mode handoff|reply] [--instruction "<text>"]
  link   list
  link   rm <wire-id>
  cron   add <card> --when "30m|07:30|hverdager 08:00" --text "<message>" [--name "<name>"]
  cron   list | rm <job-id> | run <job-id> | on <job-id> | off <job-id>
         <from>/<to>: a task id, a card title, or the start of a card id.

Talks to the running Lanebay.app over ~/Library/Application Support/Lanebay/control.sock.
Tasks are limited to \(AgentTaskContract.maximumTaskCharacters) characters; put detail in --context.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

func parse(_ arguments: [String]) -> (positional: [String], options: [String: String]) {
  var positional: [String] = []
  var options: [String: String] = [:]
  var index = 0
  while index < arguments.count {
    let argument = arguments[index]
    if argument == "--json" {
      options["json"] = "1"
    } else if argument == "--two-way" {
      options["two-way"] = "1"
    } else if argument.hasPrefix("--") {
      let key = String(argument.dropFirst(2))
      if let equals = key.firstIndex(of: "=") {
        options[String(key[..<equals])] = String(key[key.index(after: equals)...])
      } else if index + 1 < arguments.count {
        options[key] = arguments[index + 1]
        index += 1
      } else {
        fail("Missing value for \(argument).\n\n\(usage)", code: 2)
      }
    } else {
      positional.append(argument)
    }
    index += 1
  }
  return (positional, options)
}

func absolute(_ path: String) -> String {
  let expanded = (path as NSString).expandingTildeInPath
  if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
  return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).standardizedFileURL.path
}

func describe(_ record: AgentTaskRecord) -> String {
  let remaining = record.state.isFinal ? "" : " (\(AgentTaskRecord.countdown(record.remaining(now: .now))) left)"
  return "\(record.id)  \(record.state.title)\(remaining)  \(record.provider)  \(record.cwd)\n  task: \(record.task.prefix(120))\n  handoff: \(record.handoffFile)"
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage, code: 2) }
arguments.removeFirst()
if command == "-h" || command == "--help" || command == "help" { print(usage); exit(0) }
let (positional, options) = parse(arguments)
guard let op = ControlOperation(rawValue: command) else { fail("Unknown command '\(command)'.\n\n\(usage)", code: 2) }

var args: [String: String] = [:]
switch op {
case .spawn:
  guard let task = options["task"] else { fail("spawn needs --task.\n\n\(usage)", code: 2) }
  guard task.trimmingCharacters(in: .whitespacesAndNewlines).count <= AgentTaskContract.maximumTaskCharacters else {
    fail(AgentSpawnError.taskTooLong(task.count).localizedDescription, code: 2)
  }
  args["task"] = task
  args["provider"] = options["provider"] ?? "freebuff"
  args["cwd"] = absolute(options["cwd"] ?? FileManager.default.currentDirectoryPath)
  if let timeout = options["timeout"] { args["timeout"] = timeout }
  if let context = options["context"] { args["context"] = absolute(context) }
case .read:
  guard let id = positional.first else { fail("read needs a task id.", code: 2) }
  args["id"] = id
  args["tail"] = options["tail"] ?? "40"
case .send:
  guard positional.count >= 2 else { fail("send needs a task id or card name, and text.", code: 2) }
  args["id"] = positional[0]
  args["text"] = positional.dropFirst().joined(separator: " ")
case .status:
  if let id = positional.first { args["id"] = id }
case .stop:
  guard let id = positional.first else { fail("stop needs a task id.", code: 2) }
  args["id"] = id
case .list:
  break
case .link:
  let action = positional.first ?? "list"
  args["action"] = action
  switch action {
  case "add":
    guard positional.count >= 3 else { fail("link add needs <from> <to>.", code: 2) }
    args["from"] = positional[1]
    args["to"] = positional[2]
    if options["two-way"] != nil { args["two-way"] = "1" }
    if let mode = options["mode"] { args["mode"] = mode }
    if let instruction = options["instruction"] { args["instruction"] = instruction }
  case "rm":
    guard positional.count >= 2 else { fail("link rm needs a wire id.", code: 2) }
    args["id"] = positional[1]
  case "list": break
  default: fail("link takes add, list or rm.", code: 2)
  }
case .cron:
  let action = positional.first ?? "list"
  args["action"] = action
  switch action {
  case "add":
    guard positional.count >= 2, let when = options["when"], let text = options["text"] else {
      fail("cron add needs <card> --when <schedule> --text <message>.", code: 2)
    }
    args["card"] = positional[1]
    args["when"] = when
    args["text"] = text
    if let name = options["name"] { args["name"] = name }
  case "rm", "run", "on", "off":
    guard positional.count >= 2 else { fail("cron \(action) needs a job id.", code: 2) }
    args["id"] = positional[1]
  case "list": break
  default: fail("cron takes add, list, rm, run, on or off.", code: 2)
  }
}

let response: ControlResponse
do {
  response = try ControlClient().send(op: op, args: args)
} catch {
  fail(error.localizedDescription)
}
guard response.ok else { fail("lanebay: \(response.error ?? "request failed")") }
if options["json"] != nil || ProcessInfo.processInfo.environment["LANEBAY_JSON"] == "1" {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  encoder.dateEncodingStrategy = .iso8601
  if let data = try? encoder.encode(response) { print(String(decoding: data, as: UTF8.self)) }
  exit(0)
}
switch op {
case .read, .link, .cron:
  print(response.output ?? "")
case .list, .status where response.tasks != nil:
  let tasks = response.tasks ?? []
  print(tasks.isEmpty ? "No agent tasks." : tasks.map(describe).joined(separator: "\n"))
default:
  if let task = response.task { print(describe(task)) }
}
