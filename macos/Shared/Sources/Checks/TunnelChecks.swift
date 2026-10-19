import DroidBridgeShared
import Foundation

func runTunnelChecks(_ r: CheckRunner) {
    // settings descriptor
    let d = TunnelSettingsDescriptor.b1
    r.check(d.address == "198.18.0.2" && d.subnetMask == "255.255.255.252" && d.gateway == "198.18.0.1", "b1 addressing")
    r.check(d.dnsServers == ["198.18.0.1"], "virtual DNS server")
    r.check(d.includedRoutes == ["0.0.0.0/0"] && d.excludedRoutes == ["127.0.0.0/8"], "full tunnel, loopback excluded")
    r.check(d.mtu == 1500, "mtu 1500")

    // relay loss -> blocked + fail-closed effects, settings kept
    var m = TunnelStateMachine(state: .running)
    let effects = m.handle(.relayLost)
    r.check(m.state == .blocked(.relayUnavailable), "relay loss -> blocked")
    r.check(effects == [.closeAllFlows, .dropPackets, .scheduleReconnect(delaySeconds: 1)], "fail-closed effects with 1s backoff")
    r.check(!effects.contains(.removeNetworkSettings), "settings are NOT removed on relay loss")

    // backoff 1,2,4 then persistent blocked after three failures
    var delays: [Int] = []
    var m2 = TunnelStateMachine(state: .running)
    for e in m2.handle(.relayLost) { if case .scheduleReconnect(let s) = e { delays.append(s) } }
    for _ in 0..<3 {
        for e in m2.handle(.reconnectAttemptFailed) { if case .scheduleReconnect(let s) = e { delays.append(s) } }
    }
    r.check(delays == [1, 2, 4], "reconnect backoff is 1,2,4 seconds")
    r.check(m2.state == .persistentBlocked(.relayUnavailable), "persistent blocked after three failed retries")

    // reconnect success resumes
    var m3 = TunnelStateMachine(state: .blocked(.relayUnavailable))
    let ok = m3.handle(.reconnectSucceeded)
    r.check(m3.state == .running && ok.contains(.resumeIngestion) && ok.contains(.reportConnected), "reconnect success resumes ingestion")

    // explicit stop removes settings, but only after closing flows
    var m4 = TunnelStateMachine(state: .running)
    let stopEffects = m4.handle(.stop)
    r.check(m4.state == .stopped, "stop -> stopped")
    r.check(stopEffects == [.closeAllFlows, .removeNetworkSettings], "stop closes flows then removes settings")

    // persistent blocked can be revived by a HostApp reconnect request
    var m5 = TunnelStateMachine(state: .persistentBlocked(.cellularUnavailable))
    let revive = m5.handle(.reconnectRequested)
    r.check(m5.state == .reconnecting && revive == [.scheduleReconnect(delaySeconds: 0)], "reconnectRequested revives from persistent blocked")

    r.finish("tunnel")
}
