import OpeningCoreRust
import SwiftUI

/// The repertoire list with no repertoire: start one by choosing a side (the setup flow opens
/// with it), import a PGN, or take the tour on the sample.
struct EmptyLibraryView: View {
    let newRepertoire: (Side) -> Void
    let importPGN: () -> Void
    let takeTour: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Start a Repertoire")
            } icon: {
                Image(PieceLayout.assetName(side: .white, kind: .knight))
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
            }
        } description: {
            Text("Choose a side to see which replies opponents at your level play, and which ones you haven't answered yet.")
        } actions: {
            HStack(spacing: 12) {
                SideCard(side: .white, title: "White") { newRepertoire(.white) }
                SideCard(side: .black, title: "Black") { newRepertoire(.black) }
            }
            .frame(width: 280)
            Button("Import a PGN…", action: importPGN)
            Button("Take the Tour with a Sample", systemImage: "point.topleft.down.to.point.bottomright.curvepath", action: takeTour)
                .font(.footnote)
                .padding(.top, 8)
        }
    }
}
