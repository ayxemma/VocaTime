import SwiftUI

struct ChatSheetView: View {
    @Bindable var viewModel: VoiceCommandViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
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
                        action: { viewModel.chatMicrophoneTapped() }
                    )
                    .frame(maxWidth: .infinity)
                }
                .padding()
                .background(Color(.systemBackground))
            }
            .navigationTitle("Command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
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
                Text(Self.timeFormatter.string(from: message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !isUser { Spacer(minLength: 48) }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}

#Preview {
    ChatSheetView(viewModel: VoiceCommandViewModel())
}
