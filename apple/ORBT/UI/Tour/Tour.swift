import Foundation
import Observation
import SwiftUI

/// The tour on the sample repertoire (`RepertoireLibrary.addSample`): started from the Tour
/// section in Today's place, then one step at a time, each a control to use, spotlighted by
/// `TourSpotlight` with everything else dimmed and blocked (bar buttons: `tourBarButton`). A step moves on when the user does
/// what it asks, so they fill a gap of the sample and meet coverage, Biggest Gap, saving and
/// Study on the way, and end at New Repertoire for their own. Skip Tour ends it at any step.
enum Tour {
    enum Step: Int {
        /// `ready`: the Tour section offers Start Tour; the spotlight begins on the overview.
        /// `studying`: in Study, with a card that doesn't block; `finish`: back in the library,
        /// where New Repertoire opens for the user's own repertoire.
        /// `extend`: a reply to your answer still needs one; `save`: coverage is reached.
        case off = 0, ready, browse, biggestGap, answer, extend, save, study, studying, finish
    }

    /// What a step spotlights; views mark themselves with `tourTarget`.
    enum Target: Hashable {
        case browseButton, biggestGap, board, candidates, replies, save, analysis, studyBranch
    }

    static let stepKey = "tourStep"
    static let offeredKey = "tourOffered"


    static var current: Step { TourGuide.shared.step }

    /// Offers the tour: the Tour section with Start Tour.
    static func start() {
        UserDefaults.standard.set(true, forKey: offeredKey)
        TourGuide.shared.step = .ready
    }

    /// Whether the first launch has added the sample and offered the tour (once per device).
    static var wasOffered: Bool { UserDefaults.standard.bool(forKey: offeredKey) }

    /// The first launch found repertoires already (another device, an earlier version): no
    /// sample, now or when they are deleted later.
    static func markOffered() { UserDefaults.standard.set(true, forKey: offeredKey) }

    static func skip() { TourGuide.shared.step = .off }

    /// Moves on when the tour is at `from`.
    static func advance(from: Step, to: Step) {
        if current == from { TourGuide.shared.step = to }
    }

    /// The draft changed while the tour builds the line: your move, a reply, or done.
    static func draftChanged(to step: Step) {
        if [.answer, .extend, .save].contains(current), current != step { TourGuide.shared.step = step }
    }

    /// The answer was saved: one gap filled is enough, on to studying it.
    static func saved() {
        guard current == .save else { return }
        TourGuide.shared.step = .study
    }
}

/// The tour's state for the overlay: the step (kept in UserDefaults, which the library reads
/// with `@AppStorage`) and where each target is on screen.
@Observable
final class TourGuide {
    static let shared = TourGuide()

    var step: Tour.Step {
        didSet { UserDefaults.standard.set(step.rawValue, forKey: Tour.stepKey) }
    }
    /// Tour screens on screen (`tourScreen`); the spotlight shows only over them.
    var screens = 0
    /// The targets on screen, in global coordinates; a target leaves when its view does. A
    /// target made of several views (the candidate rows) is their union.
    var frames: [Tour.Target: CGRect] {
        parts.compactMapValues { parts in parts.values.map(\.frame).reduce(nil) { $0?.union($1) ?? $1 } }
    }
    private(set) var parts: [Tour.Target: [Int: (owner: UUID?, frame: CGRect)]] = [:]

    /// `owner`: the view that reports it. A view that goes clears only its own frame, not the
    /// one a view replacing it (same target and part) already reported.
    func set(_ target: Tour.Target, part: Int = 0, frame: CGRect?, owner: UUID? = nil) {
        if let frame {
            if parts[target]?[part]?.frame != frame || parts[target]?[part]?.owner != owner {
                parts[target, default: [:]][part] = (owner, frame)
            }
        } else if parts[target]?[part] != nil, owner == nil || parts[target]?[part]?.owner == owner {
            parts[target]?[part] = nil
        }
    }

    private init() {
        step = Tour.Step(rawValue: UserDefaults.standard.integer(forKey: Tour.stepKey)) ?? .off
    }
}

extension Tour.Step {
    /// The controls this step asks for; the rest of the screen is blocked.
    var targets: [Tour.Target] {
        switch self {
        case .off, .ready, .studying, .finish: []
        case .browse: [.browseButton]
        case .biggestGap: [.biggestGap]
        case .answer: [.candidates]
        case .extend: [.replies]
        case .save: [.save, .analysis]
        case .study: [.studyBranch]
        }
    }

    var title: String {
        switch self {
        case .off, .ready, .finish: ""
        case .studying: "Learn It"
        case .browse: "Gaps"
        case .biggestGap: "Find a Gap"
        case .answer: "Your Answer"
        case .extend: "Which Replies Need an Answer"
        case .save: "Coverage Target Reached"
        case .study: "Gap Closed. Now Learn It"
        }
    }

    var message: String {
        switch self {
        case .off, .ready, .finish: ""
        case .studying: "Play your moves on the board; the app plays the replies. Stuck? Tap Hint."
        case .browse: "Gaps are replies opponents at your level play often that this repertoire doesn't answer yet. Tap Browse / Edit to fill them."
        case .biggestGap: "Biggest Gap jumps to the unanswered reply you'll meet most often. Tap it."
        case .answer: "Below are your candidates: how often each is played and how it scores. Tap the one you'd play."
        case .extend: "Now it's the opponent's turn. A reply with a Covered bar is played often enough (Seen 1 in 20 games or more) to need your answer; \"Not needed\" ones are rarer. Tap a reply that needs covering."
        case .save: "Every reply here is rarer than 1 in 20 games, so this line is covered. Tap Save to add it. Not sure about a move? Analysis checks it with Stockfish first."
        case .study: "Coverage went up. Tap Study Branch to practise the line you just added: moves you miss come back sooner."
        }
    }
}

extension View {
    /// Marks this view as a tour target: the overlay spotlights it at the steps that name it.
    /// `part`: one of several views that make up the target.
    /// `part` nil: not part of it (a later row).
    func tourTarget(_ target: Tour.Target, part: Int? = 0) -> some View {
        modifier(TourTarget(target: target, part: part))
    }


    /// A toolbar button during the tour. The bars can't be dimmed or measured, so while a step
    /// runs on this screen (`running`), the button it asks for turns prominent and every other
    /// bar button is disabled: the step can only be done one way. `target` nil: never asked for.
    func tourBarButton(_ target: Tour.Target?, running: Bool) -> some View {
        modifier(TourBarButton(target: target, running: running))
    }

    /// A screen of the tour (`running`: it shows the sample): while one is on screen, the
    /// window's `TourSpotlight` dims everything around the step's targets.
    func tourScreen(running: Bool) -> some View {
        onAppear { if running { TourGuide.shared.screens += 1 } }
            .onDisappear { if running { TourGuide.shared.screens -= 1 } }
    }
}

private struct TourTarget: ViewModifier {
    let target: Tour.Target
    let part: Int?
    @State private var owner = UUID()
    @State private var frame: CGRect?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                self.frame = frame
                if let part { TourGuide.shared.set(target, part: part, frame: frame, owner: owner) }
            }
            // A List can show a reused view again where it was, without a geometry change:
            // report it again, after the disappearance that cleared it.
            .onAppear {
                Task { @MainActor in
                    if let part, let frame { TourGuide.shared.set(target, part: part, frame: frame, owner: owner) }
                }
            }
            .onDisappear {
                if let part { TourGuide.shared.set(target, part: part, frame: nil, owner: owner) }
            }
    }
}

private struct TourBarButton: ViewModifier {
    let target: Tour.Target?
    let running: Bool

    func body(content: Content) -> some View {
        let wanted = running ? TourGuide.shared.step.targets : []
        if wanted.isEmpty {
            content
        } else if let target, wanted.contains(target) {
            content.buttonStyle(.glassProminent)
        } else {
            content.disabled(true)
        }
    }
}

extension Tour.Target {
    /// In a toolbar, where `tourBarButton` marks it instead of the spotlight.
    var inBar: Bool {
        switch self {
        case .browseButton, .board, .candidates, .replies: false
        case .biggestGap, .save, .analysis, .studyBranch: true
        }
    }
}

extension Tour.Target {
    /// The bar button's accessibility label (its title), to find where the bar put it.
    var barLabel: String? {
        switch self {
        case .browseButton, .board, .candidates, .replies: nil
        case .biggestGap: "Biggest Gap"
        case .save: "Save"
        case .analysis: "Analysis"
        case .studyBranch: "Study Branch"
        }
    }
}

/// Where a toolbar button is, in window coordinates. SwiftUI hands bar buttons to the system's
/// bars, which have no SwiftUI geometry. On iOS the button is the bar button item SwiftUI made
/// for it, found by its title on the screens in the window and placed with `frame(in:)` (the
/// popover anchor API); not by the views' accessibility labels, which UIKit fills in only while
/// an assistive technology runs (in the simulator, not on a phone). On macOS it is found by its
/// accessibility label, as UI tests find it. Nil where it isn't on screen.
enum BarButtonLocator {
    static func frame(label: String) -> CGRect? {
        #if os(iOS)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows where window.isKeyWindow {
            if let frame = itemFrame(label, in: window) { return frame }
        }
        return nil
        #elseif os(macOS)
        // The toolbar is AppKit's, beside the window's content view; its SwiftUI buttons aren't
        // views but accessibility elements of the item's hosting view.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView,
              let screen = find(label, in: content.superview?.subviews.filter { $0 !== content } ?? [])
        else { return nil }
        var frame = content.convert(window.convertFromScreen(screen), from: nil)
        if !content.isFlipped { frame.origin.y = content.bounds.height - frame.maxY }
        return frame
        #else
        return nil
        #endif
    }

    /// "Save" or "Save 2" (the number of moves in the draft).
    private static func matches(_ text: String?, _ label: String) -> Bool {
        guard let text else { return false }
        return text == label || text.hasPrefix(label + " ")
    }

    #if os(iOS)
    /// The bar button items of the view controllers on screen (a screen pushed under another
    /// has left the window, with its items), depth-first.
    private static func itemFrame(_ label: String, in window: UIWindow) -> CGRect? {
        var stack = [window.rootViewController].compactMap { $0 }
        while let controller = stack.popLast() {
            stack.append(contentsOf: controller.children)
            if let presented = controller.presentedViewController { stack.append(presented) }
            guard controller.viewIfLoaded?.window === window else { continue }
            // A phone's bottom bar, or the navigation bar's items (in groups on iPad).
            let navigation = controller.navigationItem
            let groups = navigation.leadingItemGroups + navigation.centerItemGroups + navigation.trailingItemGroups
            let items = (controller.toolbarItems ?? []) + (navigation.leftBarButtonItems ?? [])
                + (navigation.rightBarButtonItems ?? []) + groups.flatMap(\.barButtonItems)
            for item in items where !item.isHidden && matches(item.title, label) {
                if let frame = item.frame(in: window), frame.width > 0, window.bounds.intersects(frame) {
                    return frame
                }
            }
        }
        return nil
    }
    #elseif os(macOS)
    /// The element's frame on screen: views and the elements they vend, depth-first, with a work
    /// stack; each view once (a view's accessibility children include some of its subviews).
    private static func find(_ label: String, in roots: [NSView]) -> CGRect? {
        var stack: [Any] = roots
        while let element = stack.popLast() {
            if let view = element as? NSView, view.isHidden { continue }
            guard let node = element as? NSAccessibilityProtocol else { continue }
            if matches(node.accessibilityLabel(), label) || matches(node.accessibilityTitle(), label) {
                let frame = node.accessibilityFrame()
                if frame.width > 0 { return frame }
            }
            if let view = element as? NSView { stack.append(contentsOf: view.subviews) }
            stack.append(contentsOf: (node.accessibilityChildren() ?? []).filter { !($0 is NSView) })
        }
        return nil
    }
    #endif
}
