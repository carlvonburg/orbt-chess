import SwiftUI
import TipKit

/// TipKit tips for what the screens can't say on their own, all in Browse and Study: how a
/// line is entered and saved, what Biggest Gap does, how to study what was saved. Each shows where it applies and
/// goes for good once its action is done, whether or not it was read (Apple's HIG, Onboarding:
/// context-specific tips rather than one flow). Never more than one on screen: each is shown in
/// a state the others aren't. Settings › Show Tips Again brings them back.
enum AppTips {
    nonisolated static let generationKey = "tipsGeneration"

    /// Part of every tip's id: Show Tips Again starts a new generation, whose tips TipKit hasn't
    /// seen (its datastore can only be reset before `Tips.configure`).
    nonisolated static var generation: Int { UserDefaults.standard.integer(forKey: generationKey) }

    static func configure() {
        try? Tips.configure([.displayFrequency(.immediate)])
    }

    /// A time, not a count: a generation is never used twice (a count can come back to one
    /// whose tips are done, after the defaults were reset or restored).
    static func showAgain() {
        UserDefaults.standard.set(Int(Date().timeIntervalSince1970), forKey: generationKey)
    }

    /// Shown once: a tap outside a popover only hides it, and TipKit would show it again on the
    /// next visit. Its ✕, or doing what it explains (`invalidate(reason: .actionPerformed)` where
    /// that action is), ends it too.
    nonisolated static var once: [any TipOption] { [Tips.MaxDisplayCount(1)] }
}

/// Popovers, each pointing at what it explains (HIG: a tip about a control shows next to it), so
/// none takes room in a list; in Browse over the board. Each is attached to its view
/// unconditionally, and its rules (TipKit parameters the views set) say when it may show, so
/// TipKit, not the view, shows and hides it.

/// In Browse, on the gap count under the board (iOS 26 shows no popover tip on a toolbar button,
/// Apple forums 804587), naming the bar's button; done when Biggest Gap is used. Only while
/// browsing saved moves with somewhere for the button to go: not while a new line is entered
/// (`SaveDraftTip` then). Tips explain, never ask for a tap: an open popover takes the first tap
/// outside it to close.
struct BiggestGapTip: Tip {
    let id = "biggestGap.\(AppTips.generation)"
    var options: [any TipOption] { AppTips.once }
    /// Saved moves on the board (no new line) with gaps below them, Biggest Gap enabled.
    @Parameter(.transient) static var canJump: Bool = false
    /// Not where your move is missing, where `AnswerTip` shows instead: one at a time.
    var rules: [Rule] { [#Rule(Self.$canJump) { $0 }, #Rule(AnswerTip.$yourMoveMissing) { !$0 }] }
    var title: Text { Text("Gaps in This Line") }
    var message: Text? { Text("Common replies below this move that you don't answer yet. \(Image(systemName: "scope")) Biggest Gap jumps to the one you'll meet most often.") }
}

/// Right after a save, on the counts under the board, naming the bar's button: building leads
/// to studying. One thing at a time: a save arms it only once `BiggestGapTip` is done, so it is
/// never shown just after that tip closes, only at a later save. Done when Study Branch is used.
struct StudyBranchTip: Tip {
    let id = "studyBranch.\(AppTips.generation)"
    var options: [any TipOption] { AppTips.once }
    /// Saved moves on the board (no new line) with moves of yours to study below.
    @Parameter(.transient) static var canStudy: Bool = false
    /// A line was just saved while the gaps tip was done; cleared when a new line is started.
    @Parameter(.transient) static var justSaved: Bool = false
    var rules: [Rule] {
        [#Rule(Self.$canStudy) { $0 }, #Rule(Self.$justSaved) { $0 }, #Rule(AnswerTip.$yourMoveMissing) { !$0 }]
    }
    var title: Text { Text("Study These Moves") }
    var message: Text? {
        Text("\(Image(systemName: "graduationcap")) Study Branch trains the moves you saved from here on: the app plays the replies and you answer.")
    }
}

/// Your move is missing on the board (a gap, or a new line at your move), on its badge; done when
/// you play a move there.
struct AnswerTip: Tip {
    let id = "answer.\(AppTips.generation)"
    var options: [any TipOption] { AppTips.once }
    @Parameter(.transient) static var yourMoveMissing: Bool = false
    var rules: [Rule] { [#Rule(Self.$yourMoveMissing) { $0 }] }
    var title: Text { Text("Add Your Move") }
    var message: Text? { Text("Your repertoire has no move here yet. Tap one of the candidates below, which show how often each is played and how it scores, or play it on the board.") }
}

/// The opponent's move in a new line, with replies that still need an answer, on the Covered
/// column; done when you play such a reply.
struct RepliesTip: Tip {
    let id = "replies.\(AppTips.generation)"
    var options: [any TipOption] { AppTips.once }
    @Parameter(.transient) static var repliesNeeded: Bool = false
    var rules: [Rule] { [#Rule(Self.$repliesNeeded) { $0 }] }
    var title: Text { Text("Replies to Cover") }
    var message: Text? { Text("A bar means the reply is common enough to need your answer. \"Not needed\" ones are rarer than your target.") }

}

/// A new line with a few of your moves, short of the coverage target, on its "New line, not
/// saved" badge; done when a line is saved. On a new repertoire the target can be many moves
/// away, and nothing needs to wait for it.
struct SaveDraftTip: Tip {
    let id = "saveDraft.\(AppTips.generation)"
    var options: [any TipOption] { AppTips.once }
    @Parameter(.transient) static var canSave: Bool = false
    var rules: [Rule] { [#Rule(Self.$canSave) { $0 }] }
    var title: Text { Text("Save as You Go") }
    var message: Text? {
        Text("\(Image(systemName: "checkmark")) saves these moves to your repertoire now, before every reply is covered. Come back to the line later to answer more.")
    }
}

/// A new line reached the coverage target (every reply is rarer than it), on its "Coverage target
/// reached" badge; done when such a line is saved.
struct SaveTip: Tip {
    let id = "save.\(AppTips.generation)"
    var options: [any TipOption] { AppTips.once }
    @Parameter(.transient) static var lineReached: Bool = false
    var rules: [Rule] { [#Rule(Self.$lineReached) { $0 }] }
    var title: Text { Text("Line Covered") }
    var message: Text? {
        Text("Every reply here is rarer than your target, so this line is long enough to save.")
    }
}

// MARK: Study

/// Study's tips, inline below the status (the room under the board): nothing covered or
/// blocked. One at a time, the first whose rules hold (`TipGroup(.firstAvailable)` in
/// `DrillView`).
enum StudyTips {
    /// A move is asked of you.
    @MainActor static func update(userTurn: Bool, newMove: Bool, recall: Bool) {
        StudyCountsTip.userTurn = userTurn
        NewMoveTip.newMove = newMove
        HintTip.recall = recall
    }
}

/// The counts beside the status (named in order, not by color: only Multicolor makes them blue,
/// red and green); done once a line is finished.
struct StudyCountsTip: Tip {
    let id = "studyCounts.\(AppTips.generation)"
    var options: [any TipOption] { AppTips.once }
    @Parameter(.transient) static var userTurn: Bool = false
    var rules: [Rule] { [#Rule(Self.$userTurn) { $0 }] }
    var title: Text { Text("Today's Moves") }
    var message: Text? {
        Text("The numbers are what's left today: new moves, moves you're learning (back within minutes) and learned moves to review. The underlined one is what you're asked now.")
    }
}

/// A new move is shown with its arrow; done when you play it.
struct NewMoveTip: Tip {
    let id = "newMove.\(AppTips.generation)"
    var options: [any TipOption] { AppTips.once }
    @Parameter(.transient) static var newMove: Bool = false
    var rules: [Rule] { [#Rule(Self.$newMove) { $0 }] }
    var title: Text { Text("A New Move") }
    var message: Text? {
        Text("The arrow shows your move. Each time you get it right it comes back later; miss it and it comes back within minutes.")
    }
}

/// A move you've learned is asked; done when Hint is used.
struct HintTip: Tip {
    let id = "hint.\(AppTips.generation)"
    var options: [any TipOption] { AppTips.once }
    @Parameter(.transient) static var recall: Bool = false
    var rules: [Rule] { [#Rule(Self.$recall) { $0 }] }
    var title: Text { Text("Can't Remember?") }
    var message: Text? {
        Text("\(Image(systemName: "lightbulb")) Hint shows the move. It counts as a miss, so the move comes back sooner.")
    }
}
