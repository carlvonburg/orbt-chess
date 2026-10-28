import SwiftUI

/// The tour's spotlight over the whole window, bars included: everything but the step's
/// targets is dimmed and takes no touches, so the only way on is the control the card points at,
/// or Skip Tour. Shown while a tour screen is (`tourScreen`) and its targets are found.
struct TourSpotlight: View {
    var body: some View {
        let guide = TourGuide.shared
        let step = guide.step
        let targets = step.targets
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let holes = guide.screens > 0
                ? targets.compactMap { guide.frames[$0] }
                    .filter { $0.intersects(frame) }
                    // Only the part on screen (rows can run on below it).
                    .map { $0.intersection(frame).offsetBy(dx: -frame.minX, dy: -frame.minY).insetBy(dx: -6, dy: -6) }
                : []
            if !holes.isEmpty {
                let shade = holes.reduce(into: Rectangle().path(in: CGRect(origin: .zero, size: proxy.size))) {
                    $0.addPath(RoundedRectangle(cornerRadius: Self.radius($1)).path(in: $1))
                }
                ZStack(alignment: .topLeading) {
                    shade
                        .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                        // Touches in the shade stop here; those in a hole reach the control.
                        .contentShape(shade, eoFill: true)
                        .onTapGesture {}
                    ForEach(holes.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: Self.radius(holes[index]))
                            .strokeBorder(.tint, lineWidth: 2)
                            .frame(width: holes[index].width, height: holes[index].height)
                            .offset(x: holes[index].minX, y: holes[index].minY)
                            .allowsHitTesting(false)
                    }
                    // Points at the first target (Save, not Analysis).
                    card(step, around: holes[0], in: proxy.size)
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        // Bar buttons have no SwiftUI geometry: look them up while the step lasts (they move
        // as the bar lays out, appears or changes its items).
        .task(id: "\(step) \(guide.screens > 0)") {
            let inBar = targets.filter(\.inBar)
            guard !inBar.isEmpty, guide.screens > 0 else { return }
            while !Task.isCancelled {
                for target in inBar {
                    guide.set(target, frame: target.barLabel.flatMap(BarButtonLocator.frame(label:)))
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Buttons (short holes) are capsules, as the buttons are; larger areas rounded rectangles.
    private static func radius(_ hole: CGRect) -> CGFloat {
        hole.height < 90 ? min(hole.width, hole.height) / 2 : 16
    }

    /// The step's instruction as a callout, on the side of the target with more room, its
    /// pointer aimed at the target.
    private func card(_ step: Tour.Step, around target: CGRect, in size: CGSize) -> some View {
        let below = target.midY < size.height / 2
        let width = min(size.width - 32, 480)
        let minX = (size.width - width) / 2
        let pointerX = min(max(target.midX - minX, 30), width - 30)
        let shape = Callout(pointerX: pointerX, pointsUp: below)
        return VStack(spacing: 0) {
            if below {
                Color.clear.frame(height: target.maxY + 4)
            } else {
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(step.title).font(.headline)
                Text(step.message).font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    SkipTourButton()
                        .font(.subheadline)
                }
            }
            .padding()
            .padding(below ? .top : .bottom, Callout.pointerHeight)
            .frame(width: width, alignment: .leading)
            // Opaque: glass would take on the shade's gray.
            .background(.cardBackground, in: shape)
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            if below {
                Spacer(minLength: 0)
            } else {
                Color.clear.frame(height: size.height - target.minY + 4)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// A rounded rectangle with a pointer on its top or bottom edge at `pointerX`, the pointer
/// inside the shape's frame.
private struct Callout: Shape {
    static let pointerHeight: CGFloat = 16
    var pointerX: CGFloat
    var pointsUp: Bool

    func path(in rect: CGRect) -> Path {
        let h = Self.pointerHeight
        let body = CGRect(x: rect.minX, y: rect.minY + (pointsUp ? h : 0),
                          width: rect.width, height: rect.height - h)
        var path = RoundedRectangle(cornerRadius: 20).path(in: body)
        let x = rect.minX + pointerX
        let base = pointsUp ? body.minY + 1 : body.maxY - 1
        let tip = pointsUp ? rect.minY : rect.maxY
        path.move(to: CGPoint(x: x - 15, y: base))
        path.addLine(to: CGPoint(x: x, y: tip))
        path.addLine(to: CGPoint(x: x + 15, y: base))
        path.closeSubpath()
        return path
    }
}
