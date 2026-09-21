package io.droidbridge.ui

import androidx.compose.foundation.layout.Arrangement
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

@Composable
fun RelayScreen(viewModel: RelayViewModel) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()

    Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Status: ${state.relayStatus}")
        Text("Cellular: ${state.cellularStatus}${state.carrierName?.let { " ($it)" } ?: ""}")
        Text("Paired Mac: ${state.pairedMacName ?: "none"}")
        Text("Active flows: ${state.activeFlows}")
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
