import SwiftUI

/// Skip Tour, confirmed first: the tour doesn't come back by itself, so the alert says where it
/// is (Settings › Show Tour).
struct SkipTourButton<Label: View>: View {
    @ViewBuilder let label: () -> Label
    @State private var confirming = false

    var body: some View {
        Button { confirming = true } label: { label() }
            .alert("Skip the Tour?", isPresented: $confirming) {
                Button("Skip Tour", role: .destructive) { withAnimation { Tour.skip() } }
                Button("Continue Tour", role: .cancel) {}
            } message: {
                Text("You can take it again any time in Settings › Show Tour.")
            }
    }
}

extension SkipTourButton where Label == Text {
    init() { self.init { Text("Skip Tour") } }
}
