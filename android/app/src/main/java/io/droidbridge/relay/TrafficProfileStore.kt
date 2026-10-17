package io.droidbridge.relay

import android.content.SharedPreferences
import io.droidbridge.network.SocketEgressPolicy

interface TrafficProfileStore {
    fun load(): TrafficProfile
    fun save(profile: TrafficProfile)
}
class MemoryTrafficProfileStore : TrafficProfileStore {
    private var profile=TrafficProfile()
    override fun load()=profile
    override fun save(profile: TrafficProfile) { this.profile=profile.copy(dnsSuffixes=profile.dnsSuffixes.toList()) }
}
class AndroidTrafficProfileStore(private val preferences: SharedPreferences) : TrafficProfileStore {
    override fun load(): TrafficProfile=runCatching {
        TrafficProfile(SocketEgressPolicy(preferences.getInt("ttl",0).takeIf {it!=0},preferences.getInt("hop",0).takeIf {it!=0}),
            preferences.getString("dns","").orEmpty().split('\n').filter {it.isNotBlank()},
            preferences.getInt("upload",0),preferences.getInt("download",0),preferences.getInt("burst",65536))
    }.getOrElse { TrafficProfile() }
    override fun save(profile: TrafficProfile) {
        check(preferences.edit().putInt("ttl",profile.socketPolicy.ipv4Ttl ?: 0).putInt("hop",profile.socketPolicy.ipv6HopLimit ?: 0)
            .putString("dns",profile.dnsSuffixes.joinToString("\n")).putInt("upload",profile.uploadBytesPerSecond)
            .putInt("download",profile.downloadBytesPerSecond).putInt("burst",profile.burstBytes).commit()) { "Could not save traffic profile" }
    }
}
