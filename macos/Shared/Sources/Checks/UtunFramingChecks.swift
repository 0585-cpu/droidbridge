import DroidBridgeShared
import Foundation

func runUtunFramingChecks(_ r: CheckRunner) {
    let ipv4 = Data([
        0x45, 0x00, 0x00, 0x14, 0, 0, 0, 0, 0x40, 0x06,
        0, 0, 10, 0, 0, 1, 93, 184, 216, 34,
    ])
    let framed = UtunFraming.encode(ipv4)

    r.check(framed.count == ipv4.count + 4, "encode adds four-byte header")
    r.check(Array(framed.prefix(4)) == [0, 0, 0, 2], "AF_INET network-order header")
    r.check(UtunFraming.decode(framed) == ipv4, "decode round-trips IPv4")
    r.check(UtunFraming.decode(Data([0, 0, 0, 30]) + ipv4) == nil, "rejects IPv6")
    r.check(UtunFraming.decode(Data([0, 0, 0, 2, 0x45])) == Data([0x45]), "accepts one-byte IPv4 payload")
    r.check(UtunFraming.decode(Data([0, 0, 2])) == nil, "rejects short frame")
    let ipv6 = Data([0x60]) + Data(count: 39)
    r.check(UtunFraming.decode(UtunFraming.encode(ipv6)) == ipv6, "IPv6 utun framing round trip")
    r.check(Array(UtunFraming.encode(ipv6).prefix(4)) == [0,0,0,30], "IPv6 uses AF_INET6")
    r.finish("utun framing")
}
