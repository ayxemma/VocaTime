import SwiftUI

struct ChatSheetView: View {
    @Bindable var viewModel: VoiceCommandViewModel
    @Environment(\.appUILanguage) private var appUILanguage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext

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

                    HStack {
                        Text(viewModel.chatStatusDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    RecordButtonView(
                        isListening: viewModel.chatFlowState == .listening,
                        isEnabled: viewModel.chatFlowState != .processing,
                        startListeningAccessibilityLabel: s.voiceStartListening,
                        stopListeningAccessibilityLabel: s.voiceStopListening,
                        action: { viewModel.chatMicrophoneTapped() }
                    )
                    .frame(maxWidth: .infinity)
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
                if viewModel.chatFlowState == .idle {
                    Task {
                        await viewModel.chatBeginListening()
                    }
                }
            }
            .onChange(of: appUILanguage) { _, newValue in
                viewModel.uiLanguage = newValue
                Task {
                    await viewModel.handleUILanguageChanged()
                }
            }
        }
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
