import SwiftUI

struct PairingApprovalView: View {
    let sas: String?
    let onApprove: () -> Void
    let onReject: () -> Void
    @State private var approved = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield").font(.system(size: 30))
                .foregroundStyle(Color(red: 0.86, green: 0.29, blue: 0.25))
            Text(approved ? "휴대폰에서도 승인해 주세요" : "두 화면의 코드를 확인해 주세요")
                .font(.system(size: 18, weight: .bold)).multilineTextAlignment(.center)
            Text("휴대폰에 표시된 숫자와 같아야 합니다.\n코드를 입력할 필요는 없어요.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            if let sas {
                Text(sas).font(.system(size: 36, weight: .semibold, design: .monospaced)).kerning(5)
                    .padding(.horizontal, 24).padding(.vertical, 18)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("확인 코드 \(sas.map(String.init).joined(separator: " "))")
            } else { ProgressView("코드 확인 중…") }
            HStack(spacing: 12) {
                Button("취소", role: .cancel, action: onReject).keyboardShortcut(.cancelAction)
                Button(approved ? "승인 대기 중…" : "코드가 같아요") {
                    approved = true
                    onApprove()
                }
                .buttonStyle(.borderedProminent).disabled(approved || sas == nil)
            }.controlSize(.large)
        }.padding(30).frame(width: 350)
            .tint(Color(red: 0.86, green: 0.29, blue: 0.25))
    }
}
