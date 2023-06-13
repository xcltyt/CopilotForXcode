import ChatPlugin
import Environment
import Foundation
import OpenAIService
import Parsing
import Terminal

public actor ShortcutInputChatPlugin: ChatPlugin {
    public static var command: String { "shortcutInput" }
    public nonisolated var name: String { "Shortcut Input" }

    let chatGPTService: any ChatGPTServiceType
    var terminal: TerminalType = Terminal()
    var isCancelled = false
    weak var delegate: ChatPluginDelegate?

    public init(inside chatGPTService: any ChatGPTServiceType, delegate: ChatPluginDelegate) {
        self.chatGPTService = chatGPTService
        self.delegate = delegate
    }

    public func send(content: String, originalMessage: String) async {
        delegate?.pluginDidStart(self)
        delegate?.pluginDidStartResponding(self)

        defer {
            delegate?.pluginDidEndResponding(self)
            delegate?.pluginDidEnd(self)
        }

        let id = "\(Self.command)-\(UUID().uuidString)"

        var content = content[...]
        let firstParenthesisParser = PrefixThrough("(")
        let shortcutNameParser = PrefixUpTo(")")

        _ = try? firstParenthesisParser.parse(&content)
        let shortcutName = try? shortcutNameParser.parse(&content)
        _ = try? PrefixThrough(")").parse(&content)

        guard let shortcutName, !shortcutName.isEmpty else {
            let id = "\(Self.command)-\(UUID().uuidString)"
            let reply = ChatMessage(
                id: id,
                role: .assistant,
                content: "Please provide the shortcut name in format: `/\(Self.command)(shortcut name)`."
            )
            await chatGPTService.mutateHistory { history in
                history.append(reply)
            }
            return
        }

        var input = String(content).trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty {
            // if no input detected, use the previous message as input
            input = await chatGPTService.history.last?.content ?? ""
        }
        
        do {
            if isCancelled { throw CancellationError() }

            let env = ProcessInfo.processInfo.environment
            let shell = env["SHELL"] ?? "/bin/bash"
            let temporaryURL = FileManager.default.temporaryDirectory
            let temporaryInputFileURL = temporaryURL
                .appendingPathComponent("\(id)-input.txt")
            let temporaryOutputFileURL = temporaryURL
                .appendingPathComponent("\(id)-output")

            try input.write(to: temporaryInputFileURL, atomically: true, encoding: .utf8)

            let command = """
            shortcuts run "\(shortcutName)" \
            -i "\(temporaryInputFileURL.path)" \
            -o "\(temporaryOutputFileURL.path)"
            """

            _ = try await terminal.runCommand(
                shell,
                arguments: ["-i", "-l", "-c", command],
                currentDirectoryPath: "/",
                environment: [:]
            )

            await Task.yield()

            if FileManager.default.fileExists(atPath: temporaryOutputFileURL.path) {
                let data = try Data(contentsOf: temporaryOutputFileURL)
                if let text = String(data: data, encoding: .utf8) {
                    if text.isEmpty { return }
                    _ = try await chatGPTService.send(content: text, summary: nil)
                } else {
                    let text = """
                    [View File](\(temporaryOutputFileURL))
                    """
                    _ = try await chatGPTService.send(content: text, summary: nil)
                }

                return
            }
        } catch {
            let id = "\(Self.command)-\(UUID().uuidString)"
            let reply = ChatMessage(
                id: id,
                role: .assistant,
                content: error.localizedDescription
            )
            await chatGPTService.mutateHistory { history in
                history.append(reply)
            }
        }
    }

    public func cancel() async {
        isCancelled = true
        await terminal.terminate()
    }

    public func stopResponding() async {
        isCancelled = true
        await terminal.terminate()
    }
}

