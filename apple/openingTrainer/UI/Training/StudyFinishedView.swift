import OpeningCoreRust
import SwiftUI

/// Shown when a study session has nothing left: this session's result, the streak, the
/// repertoire's progress and what comes next, with the actions at the bottom (iOS 26 layout).
/// Closing is the toolbar's job, so there is no Done button.
struct StudyFinishedView: View {
    @Environment(AppModel.self) private var app
    let model: DrillModel
    /// The next repertoire when studying all of them.
    let next: (name: String, start: () -> Void)?
    @State private var today = LibraryTodayModel()

    private var document: RepertoireDocument { model.document }
    private var studied: Bool { model.answeredCount > 0 }

    var body: some View {
        let timing = SchedTiming()
        let laterToday = document.sidecar.laterLearningDues(timing: timing).filter { Calendar.current.isDateInToday($0) }
        ScrollView {
            VStack(spacing: 16) {
                header(learningLater: !laterToday.isEmpty)
                if studied { sessionTiles }
                progressCard
                nextCard(laterToday: laterToday, timing: timing)
            }
            .padding()
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .safeAreaBar(edge: .bottom) { actions }
        .task { await today.load(app) }
    }

    // MARK: Content

    private func header(learningLater: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: studied ? "checkmark" : "tray")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(studied ? .green : .secondary)
                .frame(width: 64, height: 64)
                .background(studied ? AnyShapeStyle(.green.opacity(0.18)) : AnyShapeStyle(.fill.tertiary), in: .circle)
            Text(studied ? (learningLater ? "Done for Now" : "Done for Today") : "Nothing to Study")
                .font(.title2.weight(.semibold))
            if !studied {
                Text(model.isFiltered ? "There are no moves in this branch yet." : "No moves are due right now.")
                    .foregroundStyle(.secondary)
            }
            if today.streak.current > 0 {
                Label("\(today.streak.current)-day streak", systemImage: "flame.fill")
                    .font(.subheadline)
                    .foregroundStyle(today.streak.studiedToday ? .orange : .secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, 8)
    }

    private var sessionTiles: some View {
        let minutes = Int((Double(model.studiedMillis) / 60_000).rounded())
        return HStack(spacing: 10) {
            tile(model.answeredCount.formatted(), model.answeredCount == 1 ? "move" : "moves")
            tile(Format.percent(Double(model.correctCount) / Double(model.answeredCount)), "correct", tint: .green)
            tile(minutes < 1 ? "<1 min" : "\(minutes) min", "time")
        }
    }

    private func tile(_ value: String, _ label: String, tint: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.fill.quinary, in: .rect(cornerRadius: 14))
    }

    private var progressCard: some View {
        let progress = document.learningProgress()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(document.name).font(.headline).lineLimit(1)
                Spacer()
                Text("\(progress.studied) of \(progress.cards) moves").font(.subheadline).foregroundStyle(.secondary)
            }
            StudiedBar(progress: progress, height: 8)
            FlowLayout {
                legend(progress.learning, "learning", StudyColors.learningGroup)
                legend(progress.young, "young", StudyColors.young)
                legend(progress.mature, "mature", StudyColors.mature)
            }
            .font(.caption)
        }
        .padding()
        .background(.fill.quinary, in: .rect(cornerRadius: 16))
    }

    private func legend(_ value: Int64, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(value) \(label)").foregroundStyle(.secondary)
        }
    }

    /// When moves come back: learning steps later today (tap to look again), then reviews.
    @ViewBuilder
    private func nextCard(laterToday: [Date], timing: SchedTiming) -> some View {
        let tomorrow = document.sidecar.dueTomorrow(timing: timing)
        let nextReview = document.sidecar.nextDue(timing: timing).flatMap { Calendar.current.isDateInToday($0) ? nil : $0 }
        if !laterToday.isEmpty || tomorrow > 0 || nextReview != nil {
            VStack(spacing: 0) {
                if let first = laterToday.first {
                    Button { model.checkAgain() } label: {
                        nextRow("clock", "\(laterToday.count) learning \(laterToday.count == 1 ? "move" : "moves")",
                                first.formatted(date: .omitted, time: .shortened), chevron: true)
                    }
                    .buttonStyle(.plain)
                    if tomorrow > 0 || nextReview != nil { Divider().padding(.leading, 44) }
                }
                if tomorrow > 0 {
                    nextRow("calendar", "Reviews", "\(tomorrow) tomorrow")
                } else if let nextReview {
                    nextRow("calendar", "Next review", LibraryRow.nextStudyText(nextReview))
                }
            }
            .background(.fill.quinary, in: .rect(cornerRadius: 16))
        }
    }

    private func nextRow(_ icon: String, _ title: String, _ value: String, chevron: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
            if chevron { Image(systemName: "arrow.clockwise").font(.footnote).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    // MARK: Actions

    /// Main button first: the next repertoire during Study All, else studying more today.
    @ViewBuilder
    private var actions: some View {
        let notStudied = document.learningProgress().notStudied
        let extraReviews = model.isFiltered ? 0 : document.reviewsBeyondLimit()
        let canStudyMore = !model.isFiltered && (notStudied > 0 || extraReviews > 0)
        if next != nil || canStudyMore {
            VStack(spacing: 12) {
                if let next {
                    Button("Continue with \(next.name)") { next.start() }
                        .buttonStyle(.glassProminent)
                }
                if canStudyMore {
                    Menu {
                        if notStudied > 0 {
                            Section("\(notStudied) new moves not studied yet") {
                                ForEach([5, 10, 20], id: \.self) { n in
                                    Button("Learn \(n) More New Moves", systemImage: "sparkles") { model.increaseNewLimit(by: n) }
                                }
                            }
                        }
                        if extraReviews > 0 {
                            Button("Review \(extraReviews) More Moves", systemImage: "arrow.clockwise") {
                                model.increaseReviewLimit(by: extraReviews)
                            }
                        }
                    } label: {
                        Text("Study More Today")
                    }
                    .modifier(GlassButtonStyle(prominent: next == nil))
                }
            }
            .controlSize(.extraLarge)
            .buttonSizing(.flexible)
            .padding(.horizontal)
        }
    }

    private struct GlassButtonStyle: ViewModifier {
        let prominent: Bool
        func body(content: Content) -> some View {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        }
    }
}
