//
//  MenuBarPopover.swift
//  TaskFlowMac
//
//  Popover principal affiché quand on clique sur l'icône menubar.
//  Affiche les réunions du jour et les contrôles d'enregistrement.
//
//  UX Flow :
//    - Idle : bouton 🎙 "Enregistrer" en haut + liste des réunions avec 🎤
//    - Recording : banner rouge avec pause/stop/cancel
//    - Paused : banner orange
//    - Picking : sélecteur d'événement (liste cliquable) + bouton annuler
//    - Uploading : spinner
//    - Done : banner vert (3s)
//    - Error : banner orange avec message
//    - Pending uploads : bandeau orange par fichier en attente (assign/retry/delete)
//

import SwiftUI

struct MenuBarPopover: View {
    @Environment(AppState.self) private var appState
    @State private var pulseOpacity: Double = 1.0
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            headerSection
            
            Divider()
            
            // MARK: - Picking Banner (sélection d'événement après stop)
            if appState.recordingPhase == .picking {
                pickingSection
            }
            
            // MARK: - Recording Banner (si actif)
            else if appState.isRecording || appState.recordingPhase == .uploading {
                recordingBanner
                Divider()
            }
            
            // MARK: - Status Banners
            else if case .done = appState.recordingPhase {
                doneBanner
                Divider()
            }
            else if case .error(let msg) = appState.recordingPhase {
                errorBanner(msg)
                Divider()
            }
            
            // MARK: - Bouton enregistrement libre + pending uploads (si idle)
            else if appState.recordingPhase == .idle {
                ForEach(appState.pendingUploads) { pending in
                    pendingUploadRow(pending: pending)
                    Divider()
                }
                freeRecordButton
                Divider()
            }
            
            // MARK: - Meetings List (sauf pendant picking)
            if appState.recordingPhase != .picking {
                if appState.meetings.isEmpty && appState.isLoading {
                    ProgressView()
                        .padding(20)
                } else if appState.meetings.isEmpty {
                    emptyState
                } else {
                    meetingsList
                }
                
                Divider()
            }
            
            // MARK: - Footer
            footerSection
        }
        .frame(width: 380)
        .task {
            await appState.syncMeetings()
        }
        .onAppear {
            appState.scanPendingUploads()
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack {
            Text(todayFormatted)
                .font(.headline)
            
            Spacer()
            
            Button {
                Task { await appState.forceSyncMeetings() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(appState.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    // MARK: - Free Record Button (idle)
    
    private var freeRecordButton: some View {
        Button {
            appState.startRecording()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Enregistrer")
                        .font(.subheadline.weight(.medium))
                    Text("Démarrer un enregistrement libre")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Recording Banner
    
    private var recordingBanner: some View {
        HStack(spacing: 10) {
            // Indicateur visuel
            if appState.recordingPhase == .uploading {
                ProgressView()
                    .controlSize(.small)
            } else if appState.recordingPhase == .paused {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.body)
            } else {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(pulseOpacity)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            pulseOpacity = 0.3
                        }
                    }
                    .onDisappear { pulseOpacity = 1.0 }
            }
            
            VStack(alignment: .leading, spacing: 1) {
                if appState.recordingPhase == .uploading {
                    Text("Envoi pour transcription...")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                } else {
                    HStack(spacing: 6) {
                        Text(appState.recordingEvent?.displayTitle ?? "Enregistrement libre")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        
                        if appState.recordingPhase == .paused {
                            Text("PAUSE")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.15), in: Capsule())
                        }
                    }
                }
                
                if appState.isRecording {
                    Text(appState.formattedDuration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            if appState.isRecording {
                // Bouton pause / resume
                Button {
                    if appState.recordingPhase == .paused {
                        appState.resumeRecording()
                    } else {
                        appState.pauseRecording()
                    }
                } label: {
                    Image(systemName: appState.recordingPhase == .paused ? "play.fill" : "pause.fill")
                        .font(.caption)
                        .foregroundStyle(appState.recordingPhase == .paused ? .green : .orange)
                }
                .buttonStyle(.plain)
                .help(appState.recordingPhase == .paused ? "Reprendre" : "Mettre en pause")
                
                // Bouton annuler
                Button {
                    appState.cancelRecording()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Annuler l'enregistrement")
                
                // Bouton stop
                Button {
                    appState.stopRecording()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.body)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Arrêter l'enregistrement")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            appState.recordingPhase == .paused
                ? Color.orange.opacity(0.08)
                : Color.red.opacity(0.08)
        )
    }
    
    // MARK: - Picking Section (sélection d'événement)
    
    private var pickingSection: some View {
        VStack(spacing: 0) {
            // Header picking
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Enregistrement terminé")
                        .font(.subheadline.weight(.medium))
                    Text("À quelle réunion l'affecter ?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    appState.cancelPicking()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.caption2)
                        Text("Supprimer")
                            .font(.caption)
                    }
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Supprimer l'enregistrement")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.green.opacity(0.08))
            
            Divider()
            
            // Liste des réunions (cliquables pour assigner)
            if appState.meetings.isEmpty {
                VStack(spacing: 6) {
                    Text("Aucune réunion")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Rafraîchis la liste ou supprime l'enregistrement")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(appState.meetings) { event in
                        pickingRow(event: event)
                        if event.id != appState.meetings.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }
    
    /// Ligne d'événement cliquable pour l'assignation
    private func pickingRow(event: CalendarEvent) -> some View {
        Button {
            appState.assignEvent(event)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor(for: event))
                    .frame(width: 3, height: 36)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Text(event.timeRange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "arrow.up.circle")
                    .foregroundStyle(.blue)
                    .font(.body)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Done Banner
    
    private var doneBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Transcription envoyée !")
                .font(.subheadline.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.green.opacity(0.08))
    }
    
    // MARK: - Error Banner
    
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Erreur")
                    .font(.subheadline.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                appState.reset()
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .help("Réessayer")
            
            Button {
                appState.reset()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Fermer")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
    }
    
    // MARK: - Pending Upload Row (sidecar-based)
    
    private func pendingUploadRow(pending: PendingUploadInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .foregroundStyle(.orange)
                .font(.body)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(pending.isAssigned ? "En attente d'envoi" : "Fichier non assigné")
                    .font(.subheadline.weight(.medium))
                Text(pending.displayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            if pending.isAssigned {
                // Retry direct (l'événement est déjà assigné)
                Button {
                    appState.retryPendingUpload(pending)
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("Réessayer l'envoi")
                .disabled(appState.isRetryingPendingUpload)
            } else {
                // Assigner à une réunion
                Button {
                    appState.assignPendingUpload(pending)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("Assigner à une réunion")
            }
            
            Button {
                appState.discardPendingUpload(pending)
            } label: {
                Image(systemName: "trash.circle")
                    .font(.title3)
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Supprimer le fichier")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.green)
            Text("Aucune réunion aujourd'hui")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
    
    // MARK: - Meetings List
    
    private var meetingsList: some View {
        VStack(spacing: 0) {
            ForEach(appState.meetings) { event in
                meetingRow(event: event)
                if event.id != appState.meetings.last?.id {
                    Divider().padding(.leading, 16)
                }
            }
        }
    }
    
    // MARK: - Meeting Row
    
    private func meetingRow(event: CalendarEvent) -> some View {
        let isOngoing = isEventOngoing(event)
        let isRecordingThis = appState.recordingEvent?.id == event.id && appState.isRecording
        
        return HStack(spacing: 10) {
            // Barre colorée
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor(for: event))
                .frame(width: 3, height: 36)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    
                    if isRecordingThis {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(appState.recordingPhase == .paused ? .orange : .red)
                                .frame(width: 5, height: 5)
                                .opacity(appState.recordingPhase == .paused ? 1.0 : pulseOpacity)
                            Text(appState.recordingPhase == .paused ? "PAUSE" : "REC")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(appState.recordingPhase == .paused ? .orange : .red)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            (appState.recordingPhase == .paused ? Color.orange : Color.red)
                                .opacity(0.1),
                            in: Capsule()
                        )
                    }
                }
                
                HStack(spacing: 6) {
                    Text(event.timeRange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    if let lieu = event.Lieu, !lieu.isEmpty {
                        Text("\u{1f4cd} \(lieu)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            
            Spacer()
            
            // Bouton enregistrer / en cours
            if isRecordingThis {
                Image(systemName: appState.recordingPhase == .paused ? "pause.fill" : "waveform")
                    .foregroundStyle(appState.recordingPhase == .paused ? .orange : .red)
                    .font(.caption)
            } else if !appState.isRecording && appState.recordingPhase == .idle {
                Button {
                    appState.startRecording(for: event)
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Enregistrer cette réunion")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isOngoing ? Color.accentColor.opacity(0.06) : .clear)
    }
    
    // MARK: - Footer
    
    private var footerSection: some View {
        HStack {
            Text("dr / fr dans Alfred")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            
            Spacer()
            
            Button("Quitter") {
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
    
    // MARK: - Helpers
    
    private func accentColor(for event: CalendarEvent) -> Color {
        event.isPersonal
            ? Color(red: 0xE2/255, green: 0x5B/255, blue: 0x6A/255)
            : Color(red: 0xE8/255, green: 0xA5/255, blue: 0x17/255)
    }
    
    private func isEventOngoing(_ event: CalendarEvent) -> Bool {
        guard let start = event.startDate else { return false }
        let end = event.endDate ?? start.addingTimeInterval(3600)
        let now = Date()
        return now >= start && now < end
    }
    
    private var todayFormatted: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        let day = Calendar.current.component(.day, from: Date())
        if day == 1 {
            formatter.dateFormat = "EEEE 1er MMMM"
        } else {
            formatter.dateFormat = "EEEE d MMMM"
        }
        let raw = formatter.string(from: Date())
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}
