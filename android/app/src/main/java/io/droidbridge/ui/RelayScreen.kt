package io.droidbridge.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedTextField
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.droidbridge.protocol.Capability
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.droidbridge.pairing.PairingUiState
import io.droidbridge.usb.UsbAccessoryStatus

@Composable
fun RelayScreen(viewModel: RelayViewModel, onConnectUSB: () -> Unit = {}) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val usbStatus by UsbAccessoryStatus.state.collectAsStateWithLifecycle()

    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Status: ${state.relayStatus}")
        Text("USB: $usbStatus")
        OutlinedButton(onClick = onConnectUSB) { Text("Connect USB") }
        Text("Cellular: ${state.cellularStatus}${state.carrierName?.let { " ($it)" } ?: ""}")
        Text("Paired Mac: ${state.pairedMacName ?: "none"}")
        Text("Active TCP: ${state.activeFlows} · UDP: ${state.activeUdp} · UDP drops: ${state.udpDrops}")
        Text("Current bytes/s: ↑${state.uploadRate} ↓${state.downloadRate}")
        Text("IPv6: ${if(state.capabilities and Capability.TCP6 != 0L) "available" else "unavailable"} · ICMP v4/v6: ${state.capabilities and Capability.ICMP4 != 0L}/${state.capabilities and Capability.ICMP6 != 0L}")
        Text("Uploaded: ${state.uploadedBytes} · Downloaded: ${state.downloadedBytes}")
        state.error?.let { Text("Error: $it") }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(enabled = state.canStart, onClick = viewModel::onStartClicked) { Text("Start") }
            OutlinedButton(enabled = state.canStop, onClick = viewModel::onStopClicked) { Text("Stop") }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = viewModel::onPairClicked) { Text("Pair New Mac") }
            OutlinedButton(enabled = state.isPaired, onClick = viewModel::onForgetMacClicked) { Text("Forget Mac") }
        }

        var ttl by remember(state.profile) { mutableStateOf(state.profile.socketPolicy.ipv4Ttl?.toString().orEmpty()) }
        var hop by remember(state.profile) { mutableStateOf(state.profile.socketPolicy.ipv6HopLimit?.toString().orEmpty()) }
        var domains by remember(state.profile) { mutableStateOf(state.profile.dnsSuffixes.joinToString(", ")) }
        var upload by remember(state.profile) { mutableStateOf(state.profile.uploadBytesPerSecond.toString()) }
        var download by remember(state.profile) { mutableStateOf(state.profile.downloadBytesPerSecond.toString()) }
        var burst by remember(state.profile) { mutableStateOf(state.profile.burstBytes.toString()) }
        Text(if(state.canEditProfile) "Traffic profile · applied on Start" else "Active profile · stop to edit")
        Text("TTL ${state.profile.socketPolicy.ipv4Ttl ?: "OS default"} · Hop Limit ${state.profile.socketPolicy.ipv6HopLimit ?: "OS default"}; explicit options are read back on every socket.")
        OutlinedTextField(value=ttl,onValueChange={ttl=it},enabled=state.canEditProfile,label={Text("IPv4 TTL · blank = OS default")})
        OutlinedTextField(value=hop,onValueChange={hop=it},enabled=state.canEditProfile,label={Text("IPv6 Hop Limit · blank = OS default")})
        OutlinedTextField(value=domains,onValueChange={domains=it},enabled=state.canEditProfile,label={Text("DNS blocked suffixes · comma separated")})
        Text("DNS filtering may block updates. It does not cover encrypted DNS, cached answers or direct IP connections.")
        OutlinedTextField(value=upload,onValueChange={upload=it},enabled=state.canEditProfile,label={Text("Upload bytes/s · 0 = off")})
        OutlinedTextField(value=download,onValueChange={download=it},enabled=state.canEditProfile,label={Text("Download bytes/s · 0 = off")})
        OutlinedTextField(value=burst,onValueChange={burst=it},enabled=state.canEditProfile,label={Text("Burst bytes · 1,232–4,194,304")})
        Text("Limits are shared by all flows. Download shaping delays delivery after cellular reception.")
        Button(enabled=state.canEditProfile,onClick={viewModel.saveProfile(ttl,hop,domains,upload,download,burst)}) { Text("Save profile") }
        state.profileError?.let { Text(it) }

        // Six-digit SAS is shown only during a live pairing window; the secret is never displayed.
        when (val pairing = state.pairing) {
            is PairingUiState.AwaitingApproval -> {
                Text("Confirm this code matches your Mac: ${pairing.sas}")
                Text("From: ${pairing.macDisplayName}")
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Button(onClick = viewModel::onApprovePairing) { Text("Approve") }
                    OutlinedButton(onClick = viewModel::onRejectPairing) { Text("Reject") }
                }
            }
            is PairingUiState.Listening -> Text("Waiting for Mac to connect…")
            is PairingUiState.Failed -> Text("Pairing failed: ${pairing.reason}")
            is PairingUiState.Completed -> Text("Paired with ${pairing.macDisplayName}")
            else -> Unit
        }
    }
}
