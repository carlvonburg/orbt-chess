import OpeningCoreRust
import SwiftUI

/// Anki's Card Info for the move at a position: dates, interval, memory state and history.
struct CardInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: RepertoireDocument
    let node: NodeID
    /// The review log, read when the sheet appears.
    @State private var revlog: [RevlogEntry] = []

    var body: some View {
        NavigationStack {
            Form {
                if let epd = document.tree[node]?.epd, let card = document.sidecar.studyCards[epd] {
                    let graphs = Graphs(cards: [card], newCount: 0, suspendedNewCount: 0, revlog: revlog,
                                        timing: SchedTiming(), localOffsetSecs: Int64(TimeZone.current.secondsFromGMT()))
                    let info = graphs.cardInfo(card: card, epd: epd)
                    Section {
                        LabeledContent("Added", value: seconds(info.added).formatted(date: .abbreviated, time: .omitted))
                        if let first = info.firstReview { LabeledContent("First review", value: millis(first).formatted(date: .abbreviated, time: .omitted)) }
                        if let latest = info.latestReview { LabeledContent("Latest review", value: millis(latest).formatted(date: .abbreviated, time: .shortened)) }
                        if let due = info.due { LabeledContent("Due", value: seconds(due).formatted(date: .abbreviated, time: card.queue == .learn ? .shortened : .omitted)) }
                        LabeledContent("Interval", value: card.ctype == .review || card.ctype == .relearn ? "\(info.interval) days" : "Learning")
                        LabeledContent("Reviews", value: "\(info.reps)")
                        LabeledContent("Lapses", value: "\(info.lapses)\(card.leech == true ? " (leech)" : "")")
                        LabeledContent("Average time", value: String(format: "%.1f s", Double(info.averageMillis) / 1000))
                        LabeledContent("Total time", value: String(format: "%.0f s", Double(info.totalMillis) / 1000))
                        if let memory = info.memory {
                            LabeledContent("Stability", value: String(format: "%.1f days", memory.stability))
                            LabeledContent("Difficulty", value: String(format: "%.0f%%", (memory.difficulty - 1) / 9 * 100))
                        }
                        if let r = info.retrievability { LabeledContent("Retrievability", value: r.formatted(.percent.precision(.fractionLength(0)))) }
                    } header: {
                        Text(document.tree.lineText(to: node).nilIfEmpty ?? "Starting position")
                    }
                    Section("History") {
                        ForEach(info.history.reversed(), id: \.id) { entry in
                            HStack {
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                Spacer()
                                Text(kind(entry.kind)).foregroundStyle(.secondary)
                                Text(entry.ease == 1 ? "Again" : entry.ease == 0 ? "Manual" : "Good")
                                    .foregroundStyle(entry.ease == 1 ? AnyShapeStyle(.wrong) : AnyShapeStyle(.primary))
                                    .frame(width: 56, alignment: .trailing)
                            }
                            .font(.footnote)
                        }
                    }
                } else {
                    Text("This move has not been studied yet.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .task { revlog = await document.reviewLog() }
            .navigationTitle("Move Info")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }

    private func seconds(_ unix: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(unix)) }
    private func millis(_ unix: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(unix) / 1000) }

    private func kind(_ type: RevlogReviewKind) -> String {
        switch type {
        case .learning: "Learn"
        case .review: "Review"
        case .relearning: "Relearn"
        case .filtered: "Filtered"
        case .manual: "Manual"
        case .rescheduled: "Rescheduled"
        }
    }
}
