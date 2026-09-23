package io.droidbridge.relay

import io.droidbridge.network.*
import io.droidbridge.policy.DnsDomainFilter
import io.droidbridge.protocol.*
import java.io.Closeable
import java.net.Socket
import java.net.DatagramSocket

/** One immutable profile and pair of shared direction buckets per run. */
class AndroidRelayBackend(private val controller: CellularNetworkController) : RelayBackend {
    @Volatile private var traffic=RelayTrafficPolicy()
    private val icmp=AndroidIcmpEchoTransport(controller)
    private var probeGeneration=-1L
    private var pingFlags=0L
    @Synchronized fun beginRun(profile: TrafficProfile) { traffic=RelayTrafficPolicy(profile.copy(dnsSuffixes=profile.dnsSuffixes.toList())); probeGeneration=-1 }
    override fun trafficPolicy()=traffic
    override suspend fun connect(destination: OpenDestination): Socket=controller.connectTcp(destination,traffic.profile.socketPolicy)
    override suspend fun connectUdp(destination: OpenDestination): DatagramSocket=controller.connectUdp(destination,traffic.profile.socketPolicy)
    override fun release(socket: Closeable)=controller.release(socket)
    override suspend fun echo(request: IcmpRequest): IcmpReply {
        val required=if(request.family==4) Capability.ICMP4 else Capability.ICMP6
        if(capabilities().flags and required==0L) throw AddressFamilyUnavailableException()
        return icmp.echo(request,traffic)
    }
    override suspend fun resolveDns(queryPacket: ByteArray): ByteArray {
        val snapshot=controller.snapshot()
        val handle=snapshot.network as? AndroidNetworkHandle ?: throw CellularUnavailableException()
        val transport=AndroidDnsTransport(handle.network,traffic.profile.socketPolicy,traffic,controller,snapshot) { controller.currentDnsServers() }
        return CellularDnsForwarder(transport,DnsDomainFilter(traffic.profile.dnsSuffixes),controller::ipv6Available).query(queryPacket).also { controller.requireCurrent(snapshot) }
    }
    override fun carrierName(): String?=(controller.state.value as? CellularState.Available)?.carrierName
    override fun cellularReady(): Boolean=controller.state.value is CellularState.Available
    @Synchronized override fun capabilities(): RelayCapabilities {
        val generation=controller.currentGeneration()
        val available=cellularReady()
        val ipv6=available && controller.ipv6Available()
        if(available && probeGeneration!=generation) {
            pingFlags=(if(icmp.probe(4,traffic.profile.socketPolicy)) Capability.ICMP4 else 0) or
                (if(ipv6 && icmp.probe(6,traffic.profile.socketPolicy)) Capability.ICMP6 else 0)
            probeGeneration=generation
        }
        val prefix=if(ipv6) controller.nat64Prefix()?.toList() ?: emptyList() else emptyList()
        val p=traffic.profile
        val flags=Capability.PROFILES or (if(available) Capability.TCP4 or Capability.UDP4 or pingFlags else 0) or
            (if(ipv6) Capability.TCP6 or Capability.UDP6 else 0) or (if(prefix.isNotEmpty()) Capability.NAT64 else 0)
        return RelayCapabilities(flags,generation,p.socketPolicy.ipv4Ttl ?: 0,p.socketPolicy.ipv6HopLimit ?: 0,
            (if(p.dnsSuffixes.isNotEmpty()) 1 else 0) or (if(p.uploadBytesPerSecond>0 || p.downloadBytesPerSecond>0) 2 else 0),
            p.uploadBytesPerSecond.toLong(),p.downloadBytesPerSecond.toLong(),p.burstBytes.toLong(),nat64Prefix=prefix)
    }
}
