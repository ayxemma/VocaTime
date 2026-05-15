import os.log
import SwiftUI
import UIKit

struct ChatSheetView: View {
    @Bindable var viewModel: VoiceCommandViewModel
    var showsStarterPrompt: Bool = false
    var onOnboardingAction: () -> Void = {}

    @Environment(\.appUILanguage) private var appUILanguage
    @Environment(\.themePalette) private var themePalette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(SubscriptionManager.self) private var subscriptionManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AppTextSize.storageKey) private var textSizeRaw: String = AppTextSize.default.rawValue

    /// Text the user is currently composing in the input field.
    @State private var typedText: String = ""
    @State private var showStarterPrompt = false
    @FocusState private var isTextFieldFocused: Bool
    /// Throttles keyboard-driven warm-up spam when the OS sends many notifications.
    @State private var lastKeyboardWarmUpAt: Date = .distantPast

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VocaTime", category: "ChatSheet")
    private var strings: AppStrings { appUILanguage.strings }
    private var typography: AppTypography { AppTypography(textSize: AppTextSize(storageRaw: textSizeRaw)) }

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
                viewModel.subscriptionManager = subscriptionManager
                viewModel.uiLanguage = appUILanguage
                BackendWarmup.scheduleSessionWarmup()
                Self.log.info("[ChatSheet] chatAutoStart — sheet opened, beginning recording")
                if showsStarterPrompt {
                    showStarterPrompt = true
                }
                viewModel.chatSheetDidAppear()
                if showsStarterPrompt {
                    completeOnboardingFromInput()
                }
            }
            .onDisappear {
                Task {
                    await viewModel.prepareForNewSession()
                    Self.log.info("[ChatSheet] chatDismissComplete — recorder released, state reset")
                }
            }
            .onChange(of: appUILanguage) { _, newValue in
                viewModel.uiLanguage = newValue
                Task { await viewModel.handleUILanguageChanged() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                let now = Date()
                guard now.timeIntervalSince(lastKeyboardWarmUpAt) > 0.35 else { return }
                lastKeyboardWarmUpAt = now
                BackendWarmup.scheduleSessionWarmup()
            }
            // When voice capture produces a transcript, move it into the text field
            // so the user can review and edit before tapping send.
            .onChange(of: viewModel.pendingVoiceTranscript) { _, transcript in
                guard !transcript.isEmpty else { return }
                typedText = transcript
                viewModel.pendingVoiceTranscript = ""
                isTextFieldFocused = true
            }
            .onChange(of: typedText) { _, newValue in
                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    completeOnboardingFromInput()
                    showStarterPrompt = false
                }
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
            if viewModel.chatFlowState == .listening {
                HStack(spacing: 8) {
                    ChatTypingIndicatorView(foreground: themePalette.accentColor)
                    Text(s.voiceListening)
                        .font(typography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            if let title = viewModel.lastActiveChatTaskContext?.title, !title.isEmpty {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.caption2.weight(.semibold))
                        Text(s.chatEditingLabel)
                            .foregroundStyle(.secondary)
                        Text(title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .font(typography.caption)
                    Spacer(minLength: 8)
                    Button {
                        viewModel.clearActiveChatTaskContext()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Exit editing mode")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if showStarterPrompt {
                starterPrompt(s: s)
            }

            // Status label
            if !viewModel.chatStatusDescription.isEmpty, viewModel.chatFlowState != .listening {
                HStack {
                    Text(viewModel.chatStatusDescription)
                        .font(typography.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.35), value: viewModel.chatStatusDescription)
                    Spacer()
                }
            }

            // Action rows — conflict / delete / disambiguation replace the composer
            if viewModel.chatFlowState == .conflictPending {
                conflictButtons(s: s)
            } else if viewModel.chatFlowState == .deletePending {
                deleteButtons(s: s)
            } else if viewModel.chatFlowState == .editConfirmationPending {
                editConfirmationButtons
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
                .font(typography.body)
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
                    if focused {
                        BackendWarmup.scheduleSessionWarmup()
                    }
                    viewModel.chatTextEditingChanged(isFocused: focused)
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
            completeOnboardingFromInput()
            showStarterPrompt = false
            viewModel.chatMicrophoneTapped()
        } label: {
            ZStack {
                Circle()
                    .fill(isListening ? Color.red.opacity(0.15) : themePalette.accentColor.opacity(0.14))
                    .frame(width: 44, height: 44)
                Image(systemName: isListening ? "stop.fill" : "mic.fill")
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
        completeOnboardingFromInput()
        showStarterPrompt = false
        typedText = ""
        isTextFieldFocused = false
        Task { await viewModel.chatSubmitTypedText(textToSend) }
    }

    private func starterPrompt(s: AppStrings) -> some View {
        let parts = OnboardingVoiceExampleFormatting.split(s.onboardingVoiceExample)
        let examplePhrase = parts.phrase.isEmpty ? s.onboardingVoiceExample.trimmingCharacters(in: .whitespacesAndNewlines) : parts.phrase
        let accentFillOpacity = colorScheme == .dark ? 0.22 : 0.12
        let accentStrokeOpacity = colorScheme == .dark ? 0.55 : 0.38
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(themePalette.accentColor)
            VStack(alignment: .leading, spacing: 8) {
                Text(s.onboardingTapFabHint)
                    .font(typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !parts.prefix.isEmpty {
                    Text(parts.prefix)
                        .font(typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(examplePhrase)
                    .font(typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(themePalette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(themePalette.accentColor.opacity(accentFillOpacity))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(themePalette.accentColor.opacity(accentStrokeOpacity), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 4, y: 2)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                completeOnboardingFromInput()
                showStarterPrompt = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(s.paywallCloseA11y)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func completeOnboardingFromInput() {
        onOnboardingAction()
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

    // MARK: - Edit confirmation buttons

    private var editConfirmationButtons: some View {
        HStack(spacing: 8) {
            Button(appUILanguage == .en ? "Cancel" : "取消") {
                viewModel.chatCancelEditResolution()
            }
            .buttonStyle(.bordered)

            Button(appUILanguage == .en ? "Choose another" : "选择其他") {
                viewModel.chatChooseAnotherEditCandidate()
            }
            .buttonStyle(.bordered)

            Button(appUILanguage == .en ? "Yes" : "是的") {
                viewModel.chatConfirmEditCandidate()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
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
                                .font(typography.font(size: 15, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let metadata = viewModel.chatCandidateMetadata(for: task) {
                                Text(metadata)
                                .font(typography.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
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
                Group {
                    if !isUser, message.text.isEmpty {
                        ChatTypingIndicatorView(foreground: p.textPrimary.opacity(0.7))
                    } else {
                        Text(message.text)
                            .font(typography.body)
                            .foregroundStyle(isUser ? p.userBubbleForeground : p.textPrimary)
                    }
                }
                .font(typography.body)
                .frame(minHeight: 22, alignment: .leading)
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
                    .font(typography.caption)
                    .foregroundStyle(p.textSecondary.opacity(0.85))
            }
            if !isUser { Spacer(minLength: 48) }
        }
    }
}

// MARK: - Subtle “typing” indicator (empty assistant placeholder)

private struct ChatTypingIndicatorView: View {
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var foreground: Color = .secondary
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(foreground)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i % 3 ? 1.0 : 0.3)
            }
        }
        .onReceive(Timer.publish(every: 0.32, on: .main, in: .common).autoconnect()) { _ in
            guard !reduceMotion else { return }
            phase = (phase + 1) % 3
        }
    }
}

#Preview {
    ChatSheetView(viewModel: VoiceCommandViewModel())
        .environment(\.appUILanguage, .en)
        .environment(\.themePalette, .palette(for: .purple))
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(SubscriptionManager())
}
