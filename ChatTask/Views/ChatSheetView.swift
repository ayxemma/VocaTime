import os.log
import SwiftUI

struct ChatSheetView: View {
    @Bindable var viewModel: VoiceCommandViewModel
    @Environment(\.appUILanguage) private var appUILanguage
    @Environment(\.themePalette) private var themePalette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext

    @State private var autoDismissTask: Task<Void, Never>?
    /// Text the user is currently composing in the input field.
    @State private var typedText: String = ""
    @FocusState private var isTextFieldFocused: Bool

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "ChatSheet")
    private var strings: AppStrings { appUILanguage.strings }

    // MARK: - Body

    var body: some View {
        let s = strings
        NavigationStack {
            VStack(spacing: 0) {
                messageScrollView

                Divider()

                inputArea(s: s)
                    .padding()
                    .background(Color(.systemBackground))
            }
            .animation(.easeInOut(duration: 0.32), value: themePalette.theme)
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
                Self.log.info("[ChatSheet] chatAutoStart — sheet opened, beginning recording")
                Task { await viewModel.chatBeginListening() }
            }
            .onDisappear {
                autoDismissTask?.cancel()
                autoDismissTask = nil
                Task {
                    await viewModel.prepareForNewSession()
                    Self.log.info("[ChatSheet] chatDismissComplete — recorder released, state reset")
                }
            }
            .onChange(of: viewModel.chatFlowState) { _, newState in
                guard newState == .success else { return }
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
            // When voice capture produces a transcript, move it into the text field
            // so the user can review and edit before tapping send.
            .onChange(of: viewModel.pendingVoiceTranscript) { _, transcript in
                guard !transcript.isEmpty else { return }
                typedText = transcript
                viewModel.pendingVoiceTranscript = ""
                isTextFieldFocused = true
            }
        }
    }

    // MARK: - Message scroll area

    private var messageScrollView: some View {
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
            .background(themePalette.backgroundColor)
            .onChange(of: viewModel.chatMessages.count) { _, _ in
                if let last = viewModel.chatMessages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input area

    @ViewBuilder
    private func inputArea(s: AppStrings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Live partial transcript (shown while listening)
            if !viewModel.chatDraftText.isEmpty, viewModel.chatFlowState == .listening {
                Text(viewModel.chatDraftText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            // Status label
            if !viewModel.chatStatusDescription.isEmpty {
                HStack {
                    Text(viewModel.chatStatusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            // Action rows — conflict / delete / disambiguation replace the composer
            if viewModel.chatFlowState == .conflictPending {
                conflictButtons(s: s)
            } else if viewModel.chatFlowState == .deletePending {
                deleteButtons(s: s)
            } else if viewModel.chatFlowState == .disambiguating {
                disambiguationCandidateList
            } else {
                // Chat composer: text field + send button or mic button
                composerRow(s: s)
            }
        }
    }

    // MARK: - Composer row

    private func composerRow(s: AppStrings) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Text field
            TextField(s.chatTextInputPlaceholder, text: $typedText, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .focused($isTextFieldFocused)
                .submitLabel(.send)
                .onSubmit { submitTypedText() }
                .disabled(viewModel.chatFlowState == .processing)
                .onChange(of: isTextFieldFocused) { _, focused in
                    // When the user taps into the text field while recording, cancel the
                    // recording session so they can type freely without noisy audio.
                    if focused, viewModel.chatFlowState == .listening {
                        Task { await viewModel.chatCancelListening() }
                    }
                }

            // Right button: send (when text is ready) or mic (when field is empty)
            if typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                micButton(s: s)
            } else {
                sendButton
            }
        }
    }

    // MARK: - Mic button (compact, inline with the text field)

    private func micButton(s: AppStrings) -> some View {
        let isListening = viewModel.chatFlowState == .listening
        let isEnabled   = viewModel.chatFlowState != .processing

        return Button {
            isTextFieldFocused = false
            viewModel.chatMicrophoneTapped()
        } label: {
            ZStack {
                Circle()
                    .fill(isListening ? Color.red.opacity(0.15) : themePalette.accentColor.opacity(0.14))
                    .frame(width: 44, height: 44)
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isListening ? Color.red : themePalette.accentColor)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isListening)
        .accessibilityLabel(isListening ? s.voiceStopListening : s.voiceStartListening)
    }

    // MARK: - Send button

    private var sendButton: some View {
        Button(action: submitTypedText) {
            ZStack {
                Circle()
                    .fill(themePalette.primaryGradient)
                    .frame(width: 44, height: 44)
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(themePalette.isMinimal ? themePalette.accentColor : Color.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.chatFlowState == .processing)
        .accessibilityLabel("Send")
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Submit typed text

    private func submitTypedText() {
        let trimmed = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let textToSend = trimmed
        typedText = ""
        isTextFieldFocused = false
        Task { await viewModel.chatSubmitTypedText(textToSend) }
    }

    // MARK: - Conflict buttons

    private func conflictButtons(s: AppStrings) -> some View {
        HStack(spacing: 12) {
            Button(s.chatConflictCancel) { viewModel.chatCancelConflict() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

            Button(s.chatConflictAddAnyway) { viewModel.chatConfirmConflict() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 2)
    }

    // MARK: - Delete buttons

    private func deleteButtons(s: AppStrings) -> some View {
        HStack(spacing: 12) {
            Button(s.chatDeleteKeep) { viewModel.chatCancelDelete() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

            Button(s.chatDeleteConfirm) { viewModel.chatConfirmDelete() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 2)
    }

    // MARK: - Disambiguation list

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

    // MARK: - Chat bubble

    private func chatBubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        let p = themePalette
        return HStack {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(isUser ? p.userBubbleForeground : p.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background {
                        if isUser {
                            Group {
                                if p.isMinimal {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(p.accentColor.opacity(0.12))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .strokeBorder(p.accentColor.opacity(0.32), lineWidth: 1)
                                        )
                                } else {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(p.primaryGradient)
                                }
                            }
                        } else {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(p.assistantBubbleBackground)
                        }
                    }
                Text(message.timestamp.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)))
                    .font(.caption2)
                    .foregroundStyle(p.textSecondary.opacity(0.85))
            }
            if !isUser { Spacer(minLength: 48) }
        }
    }
}

#Preview {
    ChatSheetView(viewModel: VoiceCommandViewModel())
        .environment(\.appUILanguage, .en)
        .environment(\.themePalette, .palette(for: .purple))
        .environment(\.locale, Locale(identifier: "en_US"))
}
