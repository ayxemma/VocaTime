import os.log
import SwiftUI

struct ChatSheetView: View {
    @Bindable var viewModel: VoiceCommandViewModel
    @Environment(\.appUILanguage) private var appUILanguage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext

    /// Task that fires auto-dismiss after a short confirmation delay. Cancelled on disappear to prevent
    /// a stale dismiss from firing on a subsequently re-opened sheet.
    @State private var autoDismissTask: Task<Void, Never>?

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "ChatSheet")
    private var strings: AppStrings { appUILanguage.strings }

    var body: some View {
        let s = strings
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.chatMessages) { message in
                                chatBubble(message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.chatMessages.count) { _, _ in
                        if let last = viewModel.chatMessages.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    if !viewModel.chatDraftText.isEmpty, viewModel.chatFlowState == .listening {
                        Text(viewModel.chatDraftText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }

                    if !viewModel.chatStatusDescription.isEmpty {
                        HStack {
                            Text(viewModel.chatStatusDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }

                    if viewModel.chatFlowState == .conflictPending {
                        HStack(spacing: 12) {
                            Button(s.chatConflictCancel) {
                                viewModel.chatCancelConflict()
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)

                            Button(s.chatConflictAddAnyway) {
                                viewModel.chatConfirmConflict()
                            }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.top, 2)
                    } else if viewModel.chatFlowState == .deletePending {
                        HStack(spacing: 12) {
                            Button(s.chatDeleteKeep) {
                                viewModel.chatCancelDelete()
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)

                            Button(s.chatDeleteConfirm) {
                                viewModel.chatConfirmDelete()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .frame(maxWidth: .infinity)
                        }
                        .padding(.top, 2)
                    } else if viewModel.chatFlowState == .disambiguating {
                        disambiguationCandidateList
                    } else {
                        RecordButtonView(
                            isListening: viewModel.chatFlowState == .listening,
                            isEnabled: viewModel.chatFlowState != .processing,
                            startListeningAccessibilityLabel: s.voiceStartListening,
                            stopListeningAccessibilityLabel: s.voiceStopListening,
                            action: { viewModel.chatMicrophoneTapped() }
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .background(Color(.systemBackground))
            }
            .navigationTitle(s.commandTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(s.dismissDone) { dismiss() }
                }
            }
            .onAppear {
                viewModel.attachPersistence(modelContext)
                viewModel.uiLanguage = appUILanguage
                // Always auto-start — state is reset to .idle in onDisappear via prepareForNewSession().
                Self.log.info("[ChatSheet] chatAutoStart — sheet opened, beginning recording")
                Task { await viewModel.chatBeginListening() }
            }
            .onDisappear {
                // Cancel any pending auto-dismiss so it doesn't fire on a re-opened sheet.
                autoDismissTask?.cancel()
                autoDismissTask = nil
                // Tear down recording and reset all state so the next open starts clean.
                Task {
                    await viewModel.prepareForNewSession()
                    Self.log.info("[ChatSheet] chatDismissComplete — recorder released, state reset")
                }
            }
            .onChange(of: viewModel.chatFlowState) { _, newState in
                guard newState == .success else { return }
                // Let the user read the confirmation briefly, then auto-close.
                autoDismissTask?.cancel()
                autoDismissTask = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    Self.log.info("[ChatSheet] autoDismiss triggered — task saved, closing sheet")
                    dismiss()
                }
            }
            .onChange(of: appUILanguage) { _, newValue in
                viewModel.uiLanguage = newValue
                Task { await viewModel.handleUILanguageChanged() }
            }
        }
    }

    @ViewBuilder
    private var disambiguationCandidateList: some View {
        VStack(spacing: 6) {
            ForEach(viewModel.disambiguationCandidates) { task in
                Button {
                    viewModel.chatSelectCandidate(task)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let d = task.scheduledDate,
                               TaskScheduleFormatting.hasWallClockTime(d) {
                                Text(d.formatted(
                                    Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    private func chatBubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(message.timestamp.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !isUser { Spacer(minLength: 48) }
        }
    }
}

#Preview {
    ChatSheetView(viewModel: VoiceCommandViewModel())
        .environment(\.appUILanguage, .en)
        .environment(\.locale, Locale(identifier: "en_US"))
}
