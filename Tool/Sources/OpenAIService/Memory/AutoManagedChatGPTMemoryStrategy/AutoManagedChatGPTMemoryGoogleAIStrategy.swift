import Foundation
import GoogleGenerativeAI
import Logger

extension AutoManagedChatGPTMemory {
    struct GoogleAIStrategy: AutoManagedChatGPTMemoryStrategy {
        let configuration: ChatGPTConfiguration

        func countToken(_ message: ChatMessage) async -> Int {
            (await OpenAIStrategy().countToken(message)) + 20
            // Using local tiktoken instead until I find a faster solution.
            // The official solution requires sending a lot of requests when adjusting the prompt.
            // adding 20 just incase.

//            guard let model = configuration.model else {
//                return 0
//            }
//            let aiModel = GenerativeModel(name: model.info.modelName, apiKey:
//            configuration.apiKey)
//            if message.isEmpty { return 0 }
//            let modelMessage = ModelContent(message)
//            return (try? await aiModel.countTokens([modelMessage]).totalTokens) ?? 0
        }

        func countToken<F>(_: F) async -> Int where F: ChatGPTFunction {
            // function is not supported.
            return 0
        }

        /// Gemini only supports turn-based conversation. A user message must be followed
        /// by an model message.
        func reformat(_ prompt: ChatGPTPrompt) async -> ChatGPTPrompt {
            var history = prompt.history
            var reformattedHistory = [ChatMessage]()

            // We don't want to combine the new user message with others.
            let newUserMessage: ChatMessage? = if history.last?.role == .user {
                history.removeLast()
            } else {
                nil
            }

            for message in history {
                let lastIndex = reformattedHistory.endIndex - 1
                guard lastIndex >= 0 else { // first message
                    if message.role == .system {
                        reformattedHistory.append(.init(
                            role: .user,
                            content: ModelContent.convertContent(of: message)
                        ))
                        reformattedHistory.append(.init(
                            role: .assistant,
                            content: "Got it. Let's start our conversation."
                        ))
                        continue
                    }

                    reformattedHistory.append(message)
                    continue
                }

                let lastMessage = reformattedHistory[lastIndex]

                if ModelContent.convertRole(lastMessage.role) == ModelContent
                    .convertRole(message.role)
                {
                    let newMessage = ChatMessage(
                        role: message.role == .assistant ? .assistant : .user,
                        content: """
                        \(ModelContent.convertContent(of: lastMessage))

                        ======

                        \(ModelContent.convertContent(of: message))
                        """
                    )
                    reformattedHistory[lastIndex] = newMessage
                } else {
                    reformattedHistory.append(message)
                }
            }

            if let newUserMessage {
                if let last = reformattedHistory.last,
                   ModelContent.convertRole(last.role) == ModelContent
                   .convertRole(newUserMessage.role)
                {
                    // Add dummy message
                    let dummyMessage = ChatMessage(
                        role: .assistant,
                        content: "OK"
                    )
                    reformattedHistory.append(dummyMessage)
                }
                reformattedHistory.append(newUserMessage)
            }

            return .init(
                history: reformattedHistory,
                references: prompt.references,
                remainingTokenCount: prompt.remainingTokenCount
            )
        }
    }
}

extension ModelContent {
    static func convertRole(_ role: ChatMessage.Role) -> String {
        switch role {
        case .user, .system, .function:
            return "user"
        case .assistant:
            return "model"
        }
    }

    static func convertContent(of message: ChatMessage) -> String {
        switch message.role {
        case .system:
            return "System Prompt: \n\(message.content ?? " ")"
        case .user, .function:
            return message.content ?? " "
        case .assistant:
            if let functionCall = message.functionCall {
                return """
                call function: \(functionCall.name)
                arguments: \(functionCall.arguments)
                """
            } else {
                return message.content ?? " "
            }
        }
    }

    init(_ message: ChatMessage) {
        let role = Self.convertRole(message.role)
        let parts = [ModelContent.Part.text(Self.convertContent(of: message))]
        self = .init(role: role, parts: parts)
    }
}
