import SwiftUI

struct MacPairingWindow: View {
    @ObservedObject var model: MacConnectionModel

    var body: some View {
        ScrollView {
            MacPairingCard(invitation: model.pairingInvitation, enlarged: true, copyCode: model.copyPairingCode)
                .padding(24)
        }
        .frame(minWidth: 720, idealWidth: 960, minHeight: 540)
        .background(Color(red: 0.025, green: 0.04, blue: 0.14))
        .preferredColorScheme(.dark)
    }
}
