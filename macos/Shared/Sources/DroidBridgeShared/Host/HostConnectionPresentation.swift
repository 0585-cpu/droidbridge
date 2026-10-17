import Foundation

/// Presentation only: a prepared relay and retained fail-closed state must never look connected.
public struct HostConnectionPresentation: Sendable {
    public enum Action: Sendable { case pair, connect, disconnect, refresh, none }
    public enum Tone: Sendable { case neutral, accent, connected, warning }
    public let title: String
    public let detail: String
    public let symbol: String
    public let tone: Tone
    public let action: Action
    public let isBusy: Bool

    public var actionTitle: String {
        switch action {
        case .pair: "휴대폰과 페어링"
        case .connect: "연결"
        case .disconnect: "연결 해제"
        case .refresh: "다시 확인"
        case .none: "잠시만 기다려 주세요…"
        }
    }

    public static func make(state: HostAppState, runtime: TunnelRuntimeStatus?, tunnelActive: Bool, busy: Bool, paired: Bool) -> Self {
        if busy {
            return Self(title: "처리 중", detail: "네트워크 설정을 적용하고 있어요. 작업이 끝날 때까지 잠시만 기다려 주세요.", symbol: "arrow.triangle.2.circlepath", tone: .accent, action: .none, isBusy: true)
        }
        if tunnelActive {
            switch runtime {
            case .running:
                return Self(title: "연결됨", detail: "휴대폰의 모바일 인터넷을 Mac에서 사용하고 있어요.", symbol: "checkmark", tone: .connected, action: .disconnect, isBusy: false)
            case .reconnecting:
                return Self(title: "다시 연결하는 중", detail: "휴대폰 연결을 복구하고 있어요. 기다리거나 연결을 해제할 수 있어요.", symbol: "arrow.triangle.2.circlepath", tone: .accent, action: .disconnect, isBusy: true)
            case .teardownFailed:
                return Self(title: "연결 해제를 다시 시도해 주세요", detail: "네트워크 복원이 끝나지 않았어요. 연결 해제를 다시 눌러 주세요.", symbol: "exclamationmark", tone: .warning, action: .disconnect, isBusy: false)
            default:
                return Self(title: "연결이 잠시 멈췄어요", detail: "USB 연결과 휴대폰의 모바일 데이터를 확인해 주세요. 복구 전까지 인터넷은 차단됩니다.", symbol: "exclamationmark", tone: .warning, action: .disconnect, isBusy: false)
            }
        }
        switch state {
        case .idle, .deviceMissing:
            return Self(title: "휴대폰을 연결해 주세요", detail: "USB 케이블로 Android 휴대폰을 연결하고 휴대폰의 DroidBridge를 열어 주세요.", symbol: "cable.connector", tone: .neutral, action: .refresh, isBusy: false)
        case .deviceUnauthorized:
            return Self(title: "USB 연결을 허용해 주세요", detail: "휴대폰에서 DroidBridge의 USB 접근을 허용한 뒤 다시 확인해 주세요.", symbol: "lock.open", tone: .warning, action: .refresh, isBusy: false)
        case .deviceSelectionRequired:
            return Self(title: "휴대폰을 선택해 주세요", detail: "인터넷을 공유할 Android 휴대폰을 아래에서 선택해 주세요.", symbol: "iphone.gen3", tone: .neutral, action: .none, isBusy: false)
        case .deviceReady:
            return Self(title: paired ? "연결할 준비가 됐어요" : "처음 연결하는 휴대폰이에요", detail: paired ? "연결을 누르면 휴대폰의 모바일 인터넷을 사용할 수 있어요." : "두 화면의 확인 코드를 비교하면 다음부터 간편하게 연결할 수 있어요.", symbol: "cable.connector", tone: .accent, action: paired ? .connect : .pair, isBusy: false)
        case .pairing(let sas):
            return Self(title: sas == nil ? "휴대폰의 승인을 기다려요" : "같은 코드인지 확인해 주세요", detail: "휴대폰에서 ‘Mac과 페어링’을 누르고, 두 화면의 코드가 같으면 모두 승인해 주세요.", symbol: "lock.shield", tone: .accent, action: .none, isBusy: sas == nil)
        case .relayPreparing:
            return Self(title: "모바일 인터넷 확인 중", detail: "휴대폰과 안전하게 연결하고 있어요. 잠시만 기다려 주세요.", symbol: "arrow.triangle.2.circlepath", tone: .accent, action: .none, isBusy: true)
        case .relayReady(let health):
            return Self(title: health.isCellularReady ? "연결할 준비가 됐어요" : "모바일 데이터를 확인해 주세요", detail: health.isCellularReady ? "휴대폰이 준비됐어요. 연결을 눌러 인터넷 공유를 시작하세요." : "휴대폰의 모바일 데이터를 켠 뒤 다시 연결해 주세요.", symbol: "personalhotspot", tone: health.isCellularReady ? .accent : .warning, action: .connect, isBusy: false)
        case .failed:
            return Self(title: "연결을 확인해 주세요", detail: "휴대폰의 DroidBridge와 USB 권한을 확인한 뒤 다시 시도해 주세요.", symbol: "exclamationmark", tone: .warning, action: .refresh, isBusy: false)
        }
    }

    public static func byteCount(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var number = Double(value)
        var index = 0
        while number >= 1000 && index < units.count - 1 { number /= 1000; index += 1 }
        return (index == 0 ? String(value) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), number)) + " " + units[index]
    }
}
