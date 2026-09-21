import SwiftUI

struct PairingApprovalView: View {
    let sas: String?
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sas {
                Text("Confirm this code matches the phone:").font(.caption)
                Text(sas).font(.system(.title2, design: .monospaced))
                HStack {
                    Button("Approve", action: onApprove)
                    Button("Reject", action: onReject)
                }
            } else {
                Text("Pairing…").font(.caption)
            }
        }
    }
}
