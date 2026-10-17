import DroidBridgeShared

func runConnectionPresentationChecks(_ r: CheckRunner) {
    let device = AdbDevice(serial: "aoa:2-1", state: .authorized, model: "Android")
    let ready = HostAppState.deviceReady(device)
    let paired = HostConnectionPresentation.make(state: ready, runtime: .stopped, tunnelActive: false, busy: false, paired: true)
    r.check(paired.action == .connect && paired.tone != .connected, "a paired phone is ready, not already connected")
    let fresh = HostConnectionPresentation.make(state: ready, runtime: nil, tunnelActive: false, busy: false, paired: false)
    r.check(fresh.action == .pair, "an unpaired phone offers pairing before tunnel start")
    for status in [TunnelRuntimeStatus.blockedRelay, .blockedCellular, .persistentBlockedRelay, .persistentBlockedCellular, .teardownFailed] {
        let blocked = HostConnectionPresentation.make(state: .deviceMissing, runtime: status, tunnelActive: true, busy: false, paired: true)
        r.check(blocked.tone == .warning && blocked.action == .disconnect, "retained protection always exposes stop and never claims connectivity: \(status)")
    }
    let live = HostConnectionPresentation.make(state: ready, runtime: .running, tunnelActive: true, busy: false, paired: true)
    r.check(live.tone == .connected && live.action == .disconnect, "only a running tunnel shows connected")
    let pairing = HostConnectionPresentation.make(state: .pairing(sas: "123456"), runtime: .stopped, tunnelActive: false, busy: false, paired: true)
    r.check(pairing.action == .none, "pairing cannot also expose tunnel start")
    let busy = HostConnectionPresentation.make(state: ready, runtime: nil, tunnelActive: false, busy: true, paired: true)
    r.check(busy.action == .none, "an in-flight operation cannot be submitted twice")
    r.check(HostConnectionPresentation.byteCount(0) == "0 B", "zero traffic is readable")
    r.check(HostConnectionPresentation.byteCount(1_500) == "1.5 KB", "traffic is formatted in human units")
    r.check(!HostConnectionPresentation.byteCount(UInt64.max).isEmpty, "large lifetime counters do not overflow")
}
