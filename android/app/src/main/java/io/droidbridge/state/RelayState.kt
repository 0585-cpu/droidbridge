package io.droidbridge.state

enum class RelayStatus { STOPPED, STARTING, RUNNING, BLOCKED_CELLULAR, STOPPING, FAILED }
enum class CellularStatus { UNAVAILABLE, REQUESTING, AVAILABLE, LOST }

/** Immutable, framework-free relay state. Transitions are pure so they unit-test without Android. */
data class RelayState(
    val relayStatus: RelayStatus = RelayStatus.STOPPED,
    val cellularStatus: CellularStatus = CellularStatus.UNAVAILABLE,
    val carrierName: String? = null,
    val pairedMacName: String? = null,
    val activeFlows: Int = 0,
    val uploadedBytes: Long = 0,
    val downloadedBytes: Long = 0,
    val lastError: String? = null,
) {
    fun onStartRequested(): RelayState =
        if (relayStatus == RelayStatus.STOPPED || relayStatus == RelayStatus.FAILED) {
            copy(relayStatus = RelayStatus.STARTING, cellularStatus = CellularStatus.REQUESTING, lastError = null)
        } else {
            this
        }

    fun onCellularAvailable(carrier: String?): RelayState = when (relayStatus) {
        RelayStatus.STARTING, RelayStatus.BLOCKED_CELLULAR, RelayStatus.RUNNING ->
            copy(relayStatus = RelayStatus.RUNNING, cellularStatus = CellularStatus.AVAILABLE, carrierName = carrier, lastError = null)
        else -> copy(cellularStatus = CellularStatus.AVAILABLE, carrierName = carrier)
    }

    /** Fail closed: relay keeps running but every flow is dropped and no new flow may open. */
    fun onCellularLost(reason: String): RelayState = when (relayStatus) {
        RelayStatus.STARTING, RelayStatus.RUNNING, RelayStatus.BLOCKED_CELLULAR ->
            copy(relayStatus = RelayStatus.BLOCKED_CELLULAR, cellularStatus = CellularStatus.UNAVAILABLE, activeFlows = 0, lastError = reason)
        else -> copy(cellularStatus = CellularStatus.UNAVAILABLE, activeFlows = 0, lastError = reason)
    }

    fun onStopRequested(): RelayState = copy(relayStatus = RelayStatus.STOPPING)

    fun onStopped(): RelayState =
        copy(relayStatus = RelayStatus.STOPPED, cellularStatus = CellularStatus.UNAVAILABLE, activeFlows = 0, carrierName = null)

    fun onFailed(reason: String): RelayState =
        copy(relayStatus = RelayStatus.FAILED, cellularStatus = CellularStatus.UNAVAILABLE, activeFlows = 0, lastError = reason)

    fun onFlowOpened(): RelayState = copy(activeFlows = activeFlows + 1)

    fun onFlowClosed(): RelayState = copy(activeFlows = maxOf(0, activeFlows - 1))

    fun onBytesTransferred(uploaded: Long, downloaded: Long): RelayState =
        copy(uploadedBytes = saturatingAdd(uploadedBytes, uploaded), downloadedBytes = saturatingAdd(downloadedBytes, downloaded))

    fun onPeerChanged(name: String?): RelayState = copy(pairedMacName = name)

    private fun saturatingAdd(current: Long, delta: Long): Long = when {
        delta <= 0 -> current
        current > Long.MAX_VALUE - delta -> Long.MAX_VALUE
        else -> current + delta
    }
}
