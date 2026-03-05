//
//  MenuBarPopover.swift
//  TaskFlowMac
//
//  Popover principal affiché quand on clique sur l'icône menubar.
//  Affiche les réunions du jour et les contrôles d'enregistrement.
//

import SwiftUI

struct MenuBarPopover: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            headerSection
            
            Divider()
            
            // MARK: - Recording Banner (si actif)
            if appState.isRecording {
                recordingBanner
                Divider()
            }
            
            // MARK: - Meetings List
            if appState.isLoading {
                ProgressView()
                    .padding(20)
            } else if appState.meetings.isEmpty {
                emptyState
            } else {
                meetingsList
            }
            
            Divider()
            
            // MARK: - Footer
            footerSection
        }
        .frame(width: 320)
        .task {
            await loadMeetingsIfNeeded()
        }
        .handleURLScheme()
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("TaskFlow")
                    .font(.headline)
                Text(todayFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                Task { await loadMeetings() }
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
    
    // MARK: - Recording Banner
    
    private var recordingBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(pulseOpacity)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseOpacity)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(appState.recordingEvent?.displayTitle ?? "Enregistrement")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(appState.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                // TODO Phase 2 : stop + upload
                appState.stopRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    appState.markDone()
                }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.body)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.red.opacity(0.08))
    }
    
    @State private var pulseOpacity: Double = 1.0
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.green)
            Text("Aucune r\u{00e9}union aujourd'hui")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
    
    // MARK: - Meetings List
    
    private var meetingsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(appState.meetings) { event in
                    meetingRow(event: event)
                    if event.id != appState.meetings.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }
        }
        .frame(maxHeight: 300)
    }
    
    // MARK: - Meeting Row
    
    private func meetingRow(event: CalendarEvent) -> some View {
        let isOngoing = isEventOngoing(event)
        let isRecordingThis = appState.recordingEvent?.id == event.id
        
        return HStack(spacing: 10) {
            // Barre colorée
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor(for: event))
                .frame(width: 3, height: 36)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    
                    if isRecordingThis {
                        HStack(spacing: 3) {
                            Circle().fill(.red).frame(width: 5, height: 5)
                            Text("REC")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.red.opacity(0.1), in: Capsule())
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
                            .lineLimit(1)
                    }
                }
            }
            
            Spacer()
            
            // Bouton enregistrer / en cours
            if isRecordingThis {
                // Déjà en cours
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else if !appState.isRecording {
                Button {
                    // TODO Phase 2 : démarrer ScreenCaptureKit
                    appState.startRecording(for: event)
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Enregistrer cette r\u{00e9}union")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isOngoing ? Color.accentColor.opacity(0.06) : .clear)
    }
    
    // MARK: - Footer
    
    private var footerSection: some View {
        HStack {
            Text("\u{2318}\u{21e7}R d\u{00e9}marre / arr\u{00ea}te")
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
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: Date()).capitalized
    }
    
    // MARK: - Data Loading
    
    private func loadMeetingsIfNeeded() async {
        if let lastSync = appState.lastSyncDate,
           Date().timeIntervalSince(lastSync) < Config.minSyncInterval {
            return
        }
        await loadMeetings()
    }
    
    private func loadMeetings() async {
        appState.isLoading = true
        defer { appState.isLoading = false }
        
        do {
            let meetings = try await SyncService().fetchMeetings()
            appState.meetings = meetings
            appState.lastSyncDate = Date()
            print("✅ Sync: \(meetings.count) r\u{00e9}unions")
        } catch {
            print("❌ Sync failed: \(error.localizedDescription)")
        }
    }
}
