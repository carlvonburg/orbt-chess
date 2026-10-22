import Observation
import OpeningCoreRust
import SwiftUI

/// The models of the Browse and Study screens on the library's navigation path, by route.
/// A screen's model is made before its route is pushed and dropped when it is popped, so the
/// screen (its panel) and the split view's board column show the same model without either
/// telling the other.
@Observable
final class LibraryScreens {
    enum Screen {
        case builder(BuilderModel, BuilderPresentation)
        case drill(DrillModel)
        case studyAll(StudyAllModel)

        /// The model whose board the board column shows (Study All: the repertoire studied now).
        var board: Board? {
            switch self {
            case .builder(let model, let presentation): .builder(model, presentation)
            case .drill(let model): .drill(model)
            case .studyAll(let all): all.drill.map { .drill($0) }
            }
        }
    }

    enum Board {
        case builder(BuilderModel, BuilderPresentation)
        case drill(DrillModel)
    }

    private var screens: [LibraryRoute: Screen] = [:]

    func screen(for route: LibraryRoute) -> Screen? {
        screens[route]
    }

    /// Makes the models `routes` need that are not made yet. Nil when a repertoire could not
    /// be opened.
    func prepare(_ routes: [LibraryRoute], app: AppModel) async -> Bool {
        for route in routes where screens[route] == nil {
            guard let screen = await Self.make(route, app: app) else {
                if route.needsModel { return false }
                continue
            }
            screens[route] = screen
        }
        return true
    }

    /// Forgets the models of screens no longer on the path.
    func keep(_ path: [LibraryRoute]) {
        screens = screens.filter { path.contains($0.key) }
    }

    private static func make(_ route: LibraryRoute, app: AppModel) async -> Screen? {
        func open(_ id: String) async -> RepertoireDocument? {
            guard let entry = app.library.entry(id: app.currentID(id)) else { return nil }
            return await app.open(entry)
        }
        switch route {
        case .overview:
            return nil
        case .builder(let id):
            return await open(id).map { .builder(BuilderModel(document: $0), BuilderPresentation()) }
        case .gaps(let id):
            return await open(id).map { .builder(BuilderModel(document: $0), BuilderPresentation(sheet: .gaps)) }
        case .browse(let id, let node):
            return await open(id).map { .builder(BuilderModel(document: $0, start: node), BuilderPresentation()) }
        case .study(let id):
            return await open(id).map { .drill(DrillModel(document: $0, mode: .study)) }
        case .learnMore(let id):
            return await open(id).map {
                .drill(DrillModel(document: $0, mode: .study, learnMore: TrainingDefaults.learnMoreCount))
            }
        case .practice(let id):
            return await open(id).map { .drill(DrillModel(document: $0, mode: .branch(RepertoireTree.rootID))) }
        case .branch(let id, let node):
            return await open(id).map { .drill(DrillModel(document: $0, mode: .branch(node))) }
        case .studyAll(let ids):
            let all = StudyAllModel(entries: ids.compactMap { app.library.entry(id: $0) })
            await all.openCurrent(app: app)
            return .studyAll(all)
        }
    }
}

extension LibraryRoute {
    /// Browse and Study screens, whose models the library makes before pushing them.
    var needsModel: Bool {
        if case .overview = self { false } else { true }
    }
}

/// Study All: today's moves of every repertoire that has some, one repertoire after another.
@Observable
final class StudyAllModel {
    let entries: [RepertoireEntry]
    private(set) var index = 0
    /// The repertoire studied now, once its document is open.
    private(set) var drill: DrillModel?

    init(entries: [RepertoireEntry]) {
        self.entries = entries
    }

    var next: RepertoireEntry? {
        index + 1 < entries.count ? entries[index + 1] : nil
    }

    func openCurrent(app: AppModel) async {
        guard index < entries.count, let doc = await app.open(entries[index]) else {
            drill = nil
            return
        }
        drill = DrillModel(document: doc, mode: .study)
    }

    func advance(app: AppModel) async {
        guard next != nil else { return }
        index += 1
        drill = nil
        await openCurrent(app: app)
    }
}

extension EnvironmentValues {
    /// Set in the split view (iPad, Mac): Browse and Study show only their panel, and the
    /// board column their board.
    @Entry var inSplitView = false
}
