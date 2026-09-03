#!/usr/bin/env swift

import Darwin
import Foundation

struct Latency: Codable {
    let ttftMs: Double?
    let finalMs: Double?
    let generationMs: Double?
}

struct ReplayCase: Codable {
    let schemaVersion: Int
    let id: String
    let sessionId: String
    let surface: String
    let language: String
    let caretMode: String
    let engine: String
    let model: String
    let configHash: String
    let expectedAction: String
    let precedingText: String?
    let trailingText: String?
    let referenceContinuation: String?
    let prediction: String?
    let eligible: Bool
    let requested: Bool
    let generated: Bool
    let shown: Bool
    let accepted: Bool
    let suggestedCharacters: Int
    let acceptedCharacters: Int
    let retainedAICharacters: Int
    let retainedTotalAddedCharacters: Int
    let suppressionReason: String?
    let staleReason: String?
    let superseded: Bool?
    let latency: Latency?
}

struct Counts: Codable {
    let cases: Int
    let eligible: Int
    let requested: Int
    let generated: Int
    let shown: Int
    let accepted: Int
    let staleDropped: Int
    let superseded: Int
    let retainedAICharacters: Int
    let retainedTotalAddedCharacters: Int
}

struct Metrics: Codable {
    let effectiveCompletionCharacterRate: Double?
    let acceptanceRate: Double?
    let opportunitySuccessRate: Double?
    let coverageRate: Double?
    let requestRate: Double?
    let generationRate: Double?
    let showConversionRate: Double?
    let staleRate: Double?
    let supersedeRate: Double?
    let positiveCoverageRate: Double?
    let wrongShowRate: Double?
    let firstLineExactMatchRate: Double?
    let meanLongestCorrectPrefixRate: Double?
}

struct LatencySummary: Codable {
    let p50: Double?
    let p95: Double?
    let max: Double?
}

struct Latencies: Codable {
    let ttftMs: LatencySummary
    let finalMs: LatencySummary
    let generationMs: LatencySummary
}

struct Report: Codable {
    let schemaVersion: Int
    let inputCaseCount: Int
    let counts: Counts
    let metrics: Metrics
    let latency: Latencies
    let suppressionReasons: [String: Int]
    let staleReasons: [String: Int]
    let slices: [String: Int]
}

enum EvalFailure: Error, CustomStringConvertible {
    case usage
    case invalidLine(Int, String)
    case invalidCase(String, String)
    case missingCoverage([String])

    var description: String {
        switch self {
        case .usage:
            return "usage: swift scripts/eval/replay_eval.swift INPUT.jsonl [OUTPUT.json]"
        case let .invalidLine(line, message):
            return "line \(line): \(message)"
        case let .invalidCase(id, message):
            return "case \(id): \(message)"
        case let .missingCoverage(items):
            return "fixture is missing required coverage: \(items.joined(separator: ", "))"
        }
    }
}

func ratio(_ numerator: Int, _ denominator: Int) -> Double? {
    denominator == 0 ? nil : Double(numerator) / Double(denominator)
}

func percentile(_ values: [Double], _ fraction: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * fraction).rounded())
    return sorted[index]
}

func summarize(_ values: [Double]) -> LatencySummary {
    LatencySummary(p50: percentile(values, 0.50), p95: percentile(values, 0.95), max: values.max())
}

func firstLine(_ value: String) -> String {
    String(value.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
}

func longestCorrectPrefixRate(prediction: String, reference: String) -> Double? {
    let expected = Array(reference)
    guard !expected.isEmpty else { return nil }
    let actual = Array(prediction)
    var matching = 0
    for (left, right) in zip(actual, expected) {
        guard left == right else { break }
        matching += 1
    }
    return Double(matching) / Double(expected.count)
}

func validate(_ item: ReplayCase, seenIDs: inout Set<String>) throws {
    let surfaces = Set(["email", "chat", "document", "search", "code", "other"])
    guard item.schemaVersion == 1 else { throw EvalFailure.invalidCase(item.id, "schemaVersion must be 1") }
    guard !item.id.isEmpty, !seenIDs.contains(item.id) else { throw EvalFailure.invalidCase(item.id, "id is empty or duplicated") }
    seenIDs.insert(item.id)
    guard surfaces.contains(item.surface) else { throw EvalFailure.invalidCase(item.id, "unknown surface") }
    guard item.caretMode == "end" || item.caretMode == "middle" else { throw EvalFailure.invalidCase(item.id, "caretMode must be end or middle") }
    guard item.expectedAction == "show" || item.expectedAction == "suppress" else { throw EvalFailure.invalidCase(item.id, "expectedAction must be show or suppress") }

    let nonnegative = [item.suggestedCharacters, item.acceptedCharacters, item.retainedAICharacters, item.retainedTotalAddedCharacters]
    guard nonnegative.allSatisfy({ $0 >= 0 }) else { throw EvalFailure.invalidCase(item.id, "character counts must be nonnegative") }
    guard !item.requested || item.eligible else { throw EvalFailure.invalidCase(item.id, "requested requires eligible") }
    guard !item.generated || item.requested else { throw EvalFailure.invalidCase(item.id, "generated requires requested") }
    guard !item.shown || item.generated else { throw EvalFailure.invalidCase(item.id, "shown requires generated") }
    guard !item.accepted || item.shown else { throw EvalFailure.invalidCase(item.id, "accepted requires shown") }
    guard item.acceptedCharacters <= item.suggestedCharacters else { throw EvalFailure.invalidCase(item.id, "accepted characters exceed suggestion") }
    guard item.retainedAICharacters <= item.acceptedCharacters else { throw EvalFailure.invalidCase(item.id, "retained AI characters exceed accepted characters") }
    guard item.retainedAICharacters <= item.retainedTotalAddedCharacters else { throw EvalFailure.invalidCase(item.id, "retained AI characters exceed retained total") }
    guard item.accepted || item.acceptedCharacters == 0 else { throw EvalFailure.invalidCase(item.id, "unaccepted case has accepted characters") }
    if item.generated && !item.shown && item.suppressionReason == nil && item.staleReason == nil {
        throw EvalFailure.invalidCase(item.id, "generated but unshown result needs suppressionReason or staleReason")
    }
}

func loadCases(path: String) throws -> [ReplayCase] {
    let input = try String(contentsOfFile: path, encoding: .utf8)
    let decoder = JSONDecoder()
    var items: [ReplayCase] = []
    var seenIDs = Set<String>()
    for (offset, rawLine) in input.split(whereSeparator: \.isNewline).enumerated() {
        do {
            let item = try decoder.decode(ReplayCase.self, from: Data(String(rawLine).utf8))
            try validate(item, seenIDs: &seenIDs)
            items.append(item)
        } catch let failure as EvalFailure {
            throw failure
        } catch {
            throw EvalFailure.invalidLine(offset + 1, error.localizedDescription)
        }
    }
    guard !items.isEmpty else { throw EvalFailure.invalidLine(1, "input is empty") }
    return items
}

func requireCoverage(_ items: [ReplayCase]) throws {
    let surfaces = Set(items.map(\.surface))
    let requiredSurfaces = ["email", "chat", "document", "search", "code"]
    var missing = requiredSurfaces.filter { !surfaces.contains($0) }
    let hasCJK = items.contains { value in
        let language = value.language.lowercased()
        return language.hasPrefix("zh") || language.hasPrefix("ja") || language.hasPrefix("ko")
    }
    if !hasCJK { missing.append("CJK") }
    if !items.contains(where: { $0.caretMode == "middle" }) { missing.append("mid-caret") }
    guard missing.isEmpty else { throw EvalFailure.missingCoverage(missing) }
}

func makeReport(_ items: [ReplayCase]) -> Report {
    let eligible = items.filter(\.eligible)
    let requested = items.filter(\.requested)
    let generated = items.filter(\.generated)
    let shown = items.filter(\.shown)
    let accepted = items.filter(\.accepted)
    let stale = items.filter { $0.staleReason != nil }
    let superseded = items.filter { $0.superseded == true }
    let positive = items.filter { $0.expectedAction == "show" }
    let negative = items.filter { $0.expectedAction == "suppress" }
    let retainedAI = items.reduce(0) { $0 + $1.retainedAICharacters }
    let retainedTotal = items.reduce(0) { $0 + $1.retainedTotalAddedCharacters }
    let opportunitiesWithRetainedAI = eligible.filter { $0.retainedAICharacters > 0 }.count

    let comparable = positive.compactMap { item -> (String, String)? in
        guard let prediction = item.prediction, let reference = item.referenceContinuation else { return nil }
        return (prediction, reference)
    }
    let exactMatches = comparable.filter { firstLine($0.0) == firstLine($0.1) }.count
    let prefixRates = comparable.compactMap { longestCorrectPrefixRate(prediction: $0.0, reference: $0.1) }

    let metrics = Metrics(
        effectiveCompletionCharacterRate: ratio(retainedAI, retainedTotal),
        acceptanceRate: ratio(accepted.count, shown.count),
        opportunitySuccessRate: ratio(opportunitiesWithRetainedAI, eligible.count),
        coverageRate: ratio(shown.count, eligible.count),
        requestRate: ratio(requested.count, eligible.count),
        generationRate: ratio(generated.count, requested.count),
        showConversionRate: ratio(shown.count, generated.count),
        staleRate: ratio(stale.count, generated.count),
        supersedeRate: ratio(superseded.count, requested.count),
        positiveCoverageRate: ratio(positive.filter(\.shown).count, positive.count),
        wrongShowRate: ratio(negative.filter(\.shown).count, negative.count),
        firstLineExactMatchRate: ratio(exactMatches, comparable.count),
        meanLongestCorrectPrefixRate: prefixRates.isEmpty ? nil : prefixRates.reduce(0, +) / Double(prefixRates.count)
    )

    func bucket(_ values: [String?]) -> [String: Int] {
        values.compactMap { $0 }.reduce(into: [:]) { result, value in result[value, default: 0] += 1 }
    }

    var slices: [String: Int] = [:]
    for item in items {
        slices["surface:\(item.surface)", default: 0] += 1
        slices["language:\(item.language)", default: 0] += 1
        slices["caret:\(item.caretMode)", default: 0] += 1
    }

    return Report(
        schemaVersion: 1,
        inputCaseCount: items.count,
        counts: Counts(
            cases: items.count,
            eligible: eligible.count,
            requested: requested.count,
            generated: generated.count,
            shown: shown.count,
            accepted: accepted.count,
            staleDropped: stale.count,
            superseded: superseded.count,
            retainedAICharacters: retainedAI,
            retainedTotalAddedCharacters: retainedTotal
        ),
        metrics: metrics,
        latency: Latencies(
            ttftMs: summarize(items.compactMap { $0.latency?.ttftMs }),
            finalMs: summarize(items.compactMap { $0.latency?.finalMs }),
            generationMs: summarize(items.compactMap { $0.latency?.generationMs })
        ),
        suppressionReasons: bucket(items.map(\.suppressionReason)),
        staleReasons: bucket(items.map(\.staleReason)),
        slices: slices
    )
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 1 || arguments.count == 2 else { throw EvalFailure.usage }
    let items = try loadCases(path: arguments[0])
    try requireCoverage(items)
    let report = makeReport(items)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    if arguments.count == 2 {
        let outputURL = URL(fileURLWithPath: arguments[1])
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: outputURL, options: .atomic)
        print("wrote \(outputURL.path) from \(items.count) cases")
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
} catch {
    FileHandle.standardError.write(Data("replay-eval: \(error)\n".utf8))
    Darwin.exit(EXIT_FAILURE)
}
