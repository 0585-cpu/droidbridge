# Bounded Disconnect Recovery Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan inline.

**Goal:** An explicit Disconnect restores DroidBridge-owned network state even when the packet engine or its lifecycle lock stalls.

**Architecture:** Persist explicit Stop intent separately from engine state, before waiting for any engine/lifecycle lock. An independent 8-second watchdog exits a stuck helper; launchd restarts it and the new process resumes the recorded Stop. Verify removal of our service, virtual routes/DNS and PF anchor before clearing intent. Bound client replies and display recovery progress/results.

**Tech Stack:** Swift 6, NSXPC, launchd, configd/scutil, pfctl, existing signed helper.

**Spec:** User-approved recovery behavior recorded in docs/network-recovery-2026-09-28.md and this plan.

## Global Constraints
- Recovery is triggered only by explicit Disconnect or administrator recovery.
- Never disable global PF, remove another app's rules, or restart a second engine over frozen process-global lwIP state.
- Preserve pairing and existing uncommitted work. Keep the live USB tunnel off during development.
- Report removal of DroidBridge settings, not unverified internet availability.

## Review Focus
- Status or health monitoring already holds the lifecycle lock when Disconnect arrives.
- Helper dies between receipt of Stop and completion; intent must survive.
- Normal completion races with the watchdog or another Start/Stop.
- A network command stalls or restoration verification fails; retain actionable retry state.
- Host closes while recovery runs; launchd must continue without host polling.

### Task 1: Independent stop coordinator and restoration verification
**Files:** Helper/HelperStopCoordinator.swift, Helper/NetworkRecoveryVerifier.swift, Helper/HelperCommandRunner.swift, HelperChecks/DisconnectRecoveryChecks.swift, project.yml (all macOS paths beneath macos except project.yml).
**Interfaces:** request(work:reply:), resumeIfRequested(work:), isPending; verify(utun:); bounded command execution.
- [x] Add tests for persisted intent, blocked worker watchdog, restart recovery, normal completion, retries, command timeout, stale route/DNS/PF detection.
- [x] Run helper checks and record RED.
- [x] Implement coordinator and verifier; run helper checks to GREEN.

### Task 2: Wire helper and host lifecycle
**Files:** HelperService.swift, main.swift, io.droidbridge.helper.plist, CoreHost/EngineBridge.swift, CoreHost/TunnelController.swift, HostApp/Helper/HelperClient.swift, App/DroidBridgeCoordinatorAdapter.swift, UI/MenuBarContentView.swift, scripts/recover-macos-network.sh.
**Interfaces:** Keep existing XPC Stop Bool contract; bounded retries on transport interruption; cached metrics.
- [x] Wire explicit Stop before stateLock; resume pending intent at boot; keep fail-closed without intent.
- [x] Verify route/DNS before PF release and empty anchor before journal removal; show recovery progress and results.
- [x] Add stalled-engine metrics and daemon restart/configuration checks. Run helper/shared/script suites.

### Task 3: Review, signed build and delivery
- [x] Independent review of current patch, resolve material findings, verify suites.
- [x] Build signed Mac app, preserve evidence and package artifact.
- [x] Install only through authorized admin workflow; live network/USB interruption remains a separately reported validation step.

Execution note: user explicitly requested implementation, so work continued inline without another design approval. Existing uncommitted work was preserved; no commits were made. Review findings and final verification are recorded in docs/disconnect-recovery-2026-09-28.md. The user completed administrator installation; matching helper hash, signature, launchd restart policy, absent journals, and hotspot HTTPS were verified. Live USB fault injection remains unperformed.
