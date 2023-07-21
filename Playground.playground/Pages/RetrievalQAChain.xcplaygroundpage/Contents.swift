import AppKit
import Foundation
import LangChain
import OpenAIService
import PlaygroundSupport
import SwiftUI

struct QAForm: View {
    @State var intermediateAnswers = [RefineDocumentChain.IntermediateAnswer]()
    @State var relevantDocuments = [(document: Document, distance: Float)]()
    @State var duration: TimeInterval = 0
    @State var answer: String = ""
    @State var question: String = "What is Swift macros?"
    @State var isProcessing: Bool = false
    @State var url: String = "https://developer.apple.com/documentation/swift/applying-macros"

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                Form {
                    Section(header: Text("Input")) {
                        TextField("URL", text: $url)
                        TextField("Question", text: $question)
                        HStack {
                            Button("Ask") {
                                Task {
                                    do {
                                        try await ask()
                                    } catch {
                                        answer = error.localizedDescription
                                    }
                                }
                            }
                            .disabled(isProcessing)
                            
                            Text("\(duration) seconds")
                        }
                    }
                    Section(header: Text("Answer")) {
                        Text(answer)
                    }
                    Section(header: Text("Intermediate Answers")) {
                        ForEach(0..<intermediateAnswers.endIndex, id: \.self) { index in
                            let answer = intermediateAnswers[index]
                            VStack(alignment: .leading) {
                                Text(answer.answer)
                                VStack(alignment: .leading) {
                                    Text("Usefulness: \(answer.usefulness)")
                                    Text("Needs more context: \(answer.more ? "Yes" : "No")")
                                }
                                .padding()
                                .background {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(NSColor.textBackgroundColor))
                                }
                                Divider()
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            ScrollView {
                Form {
                    Section(header: Text("Relevant Documents")) {
                        ForEach(0..<relevantDocuments.endIndex, id: \.self) { index in
                            let document = relevantDocuments[index]
                            VStack(alignment: .leading) {
                                Text("\(document.distance)")
                                Text(document.document.pageContent)
                                Divider()
                            }
                            .textSelection(.enabled)
                        }
                    }
                }.formStyle(.grouped)
            }
        }
    }

    func ask() async throws {
        let start = Date().timeIntervalSince1970
        answer = ""
        relevantDocuments = []
        intermediateAnswers = []
        duration = 0
        isProcessing = true
        defer { isProcessing = false }
        guard let url = URL(string: url) else {
            answer = "Invalid URL"
            return
        }
        let embeddingConfiguration = UserPreferenceEmbeddingConfiguration().overriding()
        let embedding = OpenAIEmbedding(configuration: embeddingConfiguration)
        let store: VectorStore = try await {
            if let store = await TemporaryUSearch.view(identifier: url.absoluteString) {
                return store
            } else {
                let webLoader = WebLoader(urls: [url])
                let store = TemporaryUSearch(identifier: url.absoluteString)
                let webDocuments = try await webLoader.load()
                let splitter = RecursiveCharacterTextSplitter(
                    chunkSize: 1000,
                    chunkOverlap: 100
                )
                let splitDocuments = try await splitter.transformDocuments(webDocuments)
                let embeddedDocuments = try await embedding.embed(documents: splitDocuments)
                try await store.set(embeddedDocuments)
                return store
            }
        }()

        let qa = RetrievalQAChain(
            vectorStore: store,
            embedding: embedding
        )
        answer = try await qa.run(
            question,
            callbackManagers: [
                .init {
                    $0.on(CallbackEvents.RetrievalQADidGenerateIntermediateAnswer.self) {
                        intermediateAnswers.append($0)
                    }
                    $0.on(CallbackEvents.RetrievalQADidExtractRelevantContent.self) {
                        relevantDocuments = $0
                    }
                },
            ]
        )
        duration = Date().timeIntervalSince1970 - start
    }
}

let hostingView = NSHostingController(
    rootView: QAForm()
        .frame(width: 800, height: 800)
)

PlaygroundPage.current.needsIndefiniteExecution = true
PlaygroundPage.current.liveView = hostingView
