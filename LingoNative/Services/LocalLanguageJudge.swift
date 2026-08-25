import Foundation
import llama

struct LocalAIJudgeResult: Sendable {
    let verdict: String?
    let rawOutput: String
    let elapsedSeconds: Double
    let errorMessage: String?
}

enum LocalLlamaError: LocalizedError {
    case modelMissing
    case couldNotLoadModel
    case couldNotCreateContext
    case promptTooLong
    case decodeFailed
    case noVerdict

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "The local AI model is not installed."
        case .couldNotLoadModel:
            return "Qwen could not be loaded from disk."
        case .couldNotCreateContext:
            return "llama.cpp could not create an inference context."
        case .promptTooLong:
            return "The grading prompt was too long for the local context."
        case .decodeFailed:
            return "llama.cpp failed while generating the answer."
        case .noVerdict:
            return "Qwen did not return ACCEPT or REJECT."
        }
    }
}

/// Very conservative deterministic checks that run BEFORE Qwen.
/// They only block an AI rescue when the learner answer contains a clear meaning conflict.
/// The goal is not to understand every sentence here; it is to catch the kinds of false
/// accepts the 1.7B benchmark exposed (negation deletion, swapped roles, can vs must,
/// almost vs actually, just-arrived vs about-to-arrive, etc.).
enum LocalSemanticGuardrails {
    static func clearConflict(
        course: LanguageCourse,
        reference: String,
        learner: String
    ) -> String? {
        let referenceWords = words(reference)
        let learnerWords = words(learner)

        guard !referenceWords.isEmpty, !learnerWords.isEmpty else {
            return "empty answer"
        }

        switch course {
        case .french:
            if let reason = negationDeletionConflict(
                reference: referenceWords,
                learner: learnerWords,
                markers: ["ne", "n", "pas", "jamais", "rien", "personne", "aucun", "aucune"]
            ) {
                return reason
            }

            if let reason = approximationDeletionConflict(
                reference: referenceWords,
                learner: learnerWords,
                markers: ["presque", "failli", "faillis", "faillit", "failli"]
            ) {
                return reason
            }

            if containsOpposingConcepts(
                reference: referenceWords,
                learner: learnerWords,
                pairs: [
                    (["pouvoir", "peux", "peut", "pouvais", "pouvait", "pourrais", "pourrait"],
                     ["devoir", "dois", "doit", "devais", "devait", "devrais", "devrait"]),
                    (["acheter", "achete", "achetes", "achetons", "achetez", "achetent"],
                     ["louer", "loue", "loues", "louons", "louez", "louent"]),
                    (["emprunter", "emprunte", "empruntes", "empruntons", "empruntez", "empruntent"],
                     ["preter", "prete", "pretes", "pretons", "pretez", "pretent"]),
                    (["faim"], ["soif"]),
                    (["avant"], ["apres"]),
                    (["monter"], ["descendre"])
                ]
            ) {
                return "opposing French meaning"
            }

            if explicitSubjectConflict(
                reference: referenceWords,
                learner: learnerWords,
                groups: [["je", "j"], ["tu"], ["on", "nous"], ["il"], ["elle"], ["vous"], ["ils"], ["elles"]]
            ) {
                return "different explicit subject"
            }

            if constructionConflict(
                reference: reference,
                learner: learner,
                pastMarkers: ["venir de", "viens de", "vient de", "venons de", "venez de", "viennent de"],
                futureMarkers: ["aller ", "vais ", "vas ", "va ", "allons ", "allez ", "vont "]
            ) {
                return "near-past / near-future conflict"
            }

        case .spanish:
            if let reason = negationDeletionConflict(
                reference: referenceWords,
                learner: learnerWords,
                markers: ["no", "nunca", "jamas", "nadie", "nada", "ningun", "ninguna"]
            ) {
                return reason
            }

            if let reason = approximationDeletionConflict(
                reference: referenceWords,
                learner: learnerWords,
                markers: ["casi"]
            ) {
                return reason
            }

            if containsOpposingConcepts(
                reference: referenceWords,
                learner: learnerWords,
                pairs: [
                    (["poder", "puedo", "puedes", "puede", "podemos", "podeis", "pueden", "podria", "podrias"],
                     ["deber", "debo", "debes", "debe", "debemos", "debeis", "deben", "tengo", "tienes", "tiene", "tenemos", "teneis", "tienen"]),
                    (["comprar", "compro", "compras", "compra", "compramos", "comprais", "compran"],
                     ["alquilar", "alquilo", "alquilas", "alquila", "alquilamos", "alquilais", "alquilan"]),
                    (["prestar", "presto", "prestas", "presta", "prestamos", "prestais", "prestan"],
                     ["pedir", "pido", "pides", "pide", "pedimos", "pedis", "piden"]),
                    (["hambre"], ["sed"]),
                    (["antes"], ["despues"]),
                    (["subir"], ["bajar"])
                ]
            ) {
                return "opposing Spanish meaning"
            }

            if explicitSubjectConflict(
                reference: referenceWords,
                learner: learnerWords,
                groups: [["yo"], ["tu"], ["el"], ["ella"], ["nosotros", "nosotras"], ["vosotros", "vosotras"], ["ellos"], ["ellas"]]
            ) {
                return "different explicit subject"
            }

            if constructionConflict(
                reference: reference,
                learner: learner,
                pastMarkers: ["acabar de", "acabo de", "acabas de", "acaba de", "acabamos de", "acabais de", "acaban de"],
                futureMarkers: ["estar a punto de", "voy a", "vas a", "va a", "vamos a", "vais a", "van a"]
            ) {
                return "near-past / near-future conflict"
            }

            if spanishPickupRoleConflict(reference: reference, learner: learner) {
                return "pickup roles reversed"
            }

        case .arabic:
            // Arabic-specific deterministic guardrails will be tuned separately.
            // For now the local judge remains available without applying French/Spanish rules.
            break
        }

        return nil
    }

    private static func words(_ text: String) -> [String] {
        let folded = text
            .lowercased()
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return folded.split(separator: " ").map(String.init)
    }

    private static func negationDeletionConflict(
        reference: [String],
        learner: [String],
        markers: Set<String>
    ) -> String? {
        let referenceHasNegation = reference.contains(where: markers.contains)
        let learnerHasNegation = learner.contains(where: markers.contains)

        guard referenceHasNegation != learnerHasNegation else { return nil }

        let referenceWithout = reference.filter { !markers.contains($0) }
        let learnerWithout = learner.filter { !markers.contains($0) }

        if referenceWithout == learnerWithout {
            return "negation changed"
        }

        return nil
    }

    private static func approximationDeletionConflict(
        reference: [String],
        learner: [String],
        markers: Set<String>
    ) -> String? {
        let referenceHas = reference.contains(where: markers.contains)
        let learnerHas = learner.contains(where: markers.contains)

        guard referenceHas != learnerHas else { return nil }

        let referenceWithout = reference.filter { !markers.contains($0) }
        let learnerWithout = learner.filter { !markers.contains($0) }

        if referenceWithout == learnerWithout {
            return "almost / actually changed"
        }

        return nil
    }

    private static func containsOpposingConcepts(
        reference: [String],
        learner: [String],
        pairs: [([String], [String])]
    ) -> Bool {
        for (left, right) in pairs {
            let referenceLeft = !Set(reference).isDisjoint(with: left)
            let referenceRight = !Set(reference).isDisjoint(with: right)
            let learnerLeft = !Set(learner).isDisjoint(with: left)
            let learnerRight = !Set(learner).isDisjoint(with: right)

            if (referenceLeft && learnerRight && !referenceRight && !learnerLeft)
                || (referenceRight && learnerLeft && !referenceLeft && !learnerRight) {
                return true
            }
        }
        return false
    }

    private static func explicitSubjectConflict(
        reference: [String],
        learner: [String],
        groups: [[String]]
    ) -> Bool {
        func subjectIndex(in words: [String]) -> Int? {
            for (index, group) in groups.enumerated() {
                if !Set(words).isDisjoint(with: group) {
                    return index
                }
            }
            return nil
        }

        guard let referenceSubject = subjectIndex(in: reference),
              let learnerSubject = subjectIndex(in: learner) else {
            return false
        }

        return referenceSubject != learnerSubject
    }

    private static func constructionConflict(
        reference: String,
        learner: String,
        pastMarkers: [String],
        futureMarkers: [String]
    ) -> Bool {
        let referenceText = normalizedPhrase(reference)
        let learnerText = normalizedPhrase(learner)

        let referencePast = pastMarkers.contains { referenceText.contains($0) }
        let referenceFuture = futureMarkers.contains { referenceText.contains($0) }
        let learnerPast = pastMarkers.contains { learnerText.contains($0) }
        let learnerFuture = futureMarkers.contains { learnerText.contains($0) }

        return (referencePast && learnerFuture) || (referenceFuture && learnerPast)
    }

    private static func spanishPickupRoleConflict(
        reference: String,
        learner: String
    ) -> Bool {
        let referenceText = normalizedPhrase(reference)
        let learnerText = normalizedPhrase(learner)

        let referencePickMe =
            referenceText.contains("recogeme")
            || referenceText.contains("me recoges")
            || referenceText.contains("recogerme")

        let learnerPickMe =
            learnerText.contains("recogeme")
            || learnerText.contains("me recoges")
            || learnerText.contains("recogerme")

        let referencePickYou =
            referenceText.contains("te recojo")
            || referenceText.contains("recogerte")

        let learnerPickYou =
            learnerText.contains("te recojo")
            || learnerText.contains("recogerte")

        return (referencePickMe && learnerPickYou && !referencePickYou && !learnerPickMe)
            || (referencePickYou && learnerPickMe && !referencePickMe && !learnerPickYou)
    }

    private static func normalizedPhrase(_ text: String) -> String {
        text
            .lowercased()
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
    }
}

private func localLlamaBatchClear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

private func localLlamaBatchAdd(
    _ batch: inout llama_batch,
    token: llama_token,
    position: llama_pos,
    sequenceIDs: [llama_seq_id],
    logits: Bool
) {
    let index = Int(batch.n_tokens)
    batch.token[index] = token
    batch.pos[index] = position
    batch.n_seq_id[index] = Int32(sequenceIDs.count)

    for sequenceIndex in 0..<sequenceIDs.count {
        batch.seq_id[index]![sequenceIndex] = sequenceIDs[sequenceIndex]
    }

    batch.logits[index] = logits ? 1 : 0
    batch.n_tokens += 1
}

/// Thin one-model llama.cpp wrapper for Lingo Native's local semantic grader.
///
/// Qwen runs with a conservative partial Metal offload on the standard iPhone 15.
/// Full Metal offload previously behaved unreliably, so only a small number of layers
/// are sent to the GPU while the rest remain on CPU.
private final class LocalLlamaEngine {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private var batch: llama_batch
    private var temporaryUTF8: [CChar] = []

    private init(
        model: OpaquePointer,
        context: OpaquePointer,
        sampler: UnsafeMutablePointer<llama_sampler>
    ) {
        self.model = model
        self.context = context
        self.sampler = sampler
        self.vocab = llama_model_get_vocab(model)
        self.batch = llama_batch_init(1024, 0, 1)
    }

    deinit {
        llama_sampler_free(sampler)
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
        llama_backend_free()
    }

    static func load(path: String) throws -> LocalLlamaEngine {
        llama_backend_init()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 8

        guard let model = llama_model_load_from_file(path, modelParams) else {
            llama_backend_free()
            throw LocalLlamaError.couldNotLoadModel
        }

        let threadCount = max(2, min(6, ProcessInfo.processInfo.processorCount - 2))
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 1024
        contextParams.n_threads = Int32(threadCount)
        contextParams.n_threads_batch = Int32(threadCount)

        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            llama_backend_free()
            throw LocalLlamaError.couldNotCreateContext
        }

        guard let sampler = llama_sampler_init_greedy() else {
            llama_free(context)
            llama_model_free(model)
            llama_backend_free()
            throw LocalLlamaError.couldNotCreateContext
        }

        return LocalLlamaEngine(
            model: model,
            context: context,
            sampler: sampler
        )
    }

    func generate(prompt: String, maxNewTokens: Int = 192) throws -> String {
        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)
        temporaryUTF8.removeAll(keepingCapacity: true)

        let promptTokens = try tokenize(
            text: prompt,
            addBOS: false,
            parseSpecial: true
        )

        let contextSize = Int(llama_n_ctx(context))
        guard promptTokens.count + maxNewTokens < contextSize,
              promptTokens.count < 1024 else {
            throw LocalLlamaError.promptTooLong
        }

        localLlamaBatchClear(&batch)

        for (index, token) in promptTokens.enumerated() {
            localLlamaBatchAdd(
                &batch,
                token: token,
                position: Int32(index),
                sequenceIDs: [0],
                logits: false
            )
        }

        guard batch.n_tokens > 0 else {
            throw LocalLlamaError.decodeFailed
        }

        batch.logits[Int(batch.n_tokens) - 1] = 1

        guard llama_decode(context, batch) == 0 else {
            throw LocalLlamaError.decodeFailed
        }

        var currentPosition = Int32(promptTokens.count)
        var output = ""

        for _ in 0..<maxNewTokens {
            let token = llama_sampler_sample(
                sampler,
                context,
                batch.n_tokens - 1
            )

            if llama_vocab_is_eog(vocab, token) {
                break
            }

            output += tokenString(token)

            localLlamaBatchClear(&batch)
            localLlamaBatchAdd(
                &batch,
                token: token,
                position: currentPosition,
                sequenceIDs: [0],
                logits: true
            )

            guard llama_decode(context, batch) == 0 else {
                throw LocalLlamaError.decodeFailed
            }

            currentPosition += 1
        }

        return output
    }

    private func tokenize(
        text: String,
        addBOS: Bool,
        parseSpecial: Bool
    ) throws -> [llama_token] {
        let utf8Count = text.utf8.count
        var capacity = max(128, utf8Count + 32)

        while true {
            let buffer = UnsafeMutablePointer<llama_token>.allocate(capacity: capacity)
            defer { buffer.deallocate() }

            let count = llama_tokenize(
                vocab,
                text,
                Int32(utf8Count),
                buffer,
                Int32(capacity),
                addBOS,
                parseSpecial
            )

            if count >= 0 {
                return (0..<Int(count)).map { buffer[$0] }
            }

            capacity = max(capacity * 2, Int(-count))

            if capacity > 8192 {
                throw LocalLlamaError.promptTooLong
            }
        }
    }

    private func tokenString(_ token: llama_token) -> String {
        let initialCapacity = 16
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: initialCapacity)
        buffer.initialize(repeating: 0, count: initialCapacity)
        defer { buffer.deallocate() }

        let count = llama_token_to_piece(
            vocab,
            token,
            buffer,
            Int32(initialCapacity),
            0,
            false
        )

        let bytes: [CChar]

        if count < 0 {
            let required = Int(-count)
            let larger = UnsafeMutablePointer<Int8>.allocate(capacity: required)
            larger.initialize(repeating: 0, count: required)
            defer { larger.deallocate() }

            let secondCount = llama_token_to_piece(
                vocab,
                token,
                larger,
                Int32(required),
                0,
                false
            )

            guard secondCount > 0 else { return "" }
            bytes = Array(
                UnsafeBufferPointer(
                    start: larger,
                    count: Int(secondCount)
                )
            )
        } else if count > 0 {
            bytes = Array(
                UnsafeBufferPointer(
                    start: buffer,
                    count: Int(count)
                )
            )
        } else {
            return ""
        }

        temporaryUTF8.append(contentsOf: bytes)

        if let string = String(validatingUTF8: temporaryUTF8 + [0]) {
            temporaryUTF8.removeAll(keepingCapacity: true)
            return string
        }

        return ""
    }
}

actor LocalLanguageJudge {
    static let shared = LocalLanguageJudge()

    private var engine: LocalLlamaEngine?

    /// Loads Qwen into memory without generating. Lessons call this quietly on entry so
    /// the occasional semantic rescue does not also pay model-load time.
    func prewarm() -> String? {
        do {
            guard FileManager.default.fileExists(atPath: LocalAIModelFiles.modelURL.path) else {
                throw LocalLlamaError.modelMissing
            }
            if engine == nil {
                engine = try LocalLlamaEngine.load(path: LocalAIModelFiles.modelURL.path)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func judge(
        language: String,
        register: String,
        english: String,
        reference: String,
        learner: String,
        context: String = ""
    ) -> LocalAIJudgeResult {
        let started = Date()

        do {
            if let prewarmError = prewarm() {
                throw NSError(
                    domain: "LingoNative.LocalAI",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: prewarmError]
                )
            }

            guard let engine else {
                throw LocalLlamaError.couldNotCreateContext
            }

            let prompt = Self.prompt(
                language: language,
                register: register,
                english: english,
                reference: reference,
                learner: learner,
                context: context
            )

            let raw = try engine.generate(prompt: prompt, maxNewTokens: 32)
            let verdict = Self.lastVerdict(in: raw)

            guard let verdict else {
                throw LocalLlamaError.noVerdict
            }

            return LocalAIJudgeResult(
                verdict: verdict,
                rawOutput: raw,
                elapsedSeconds: Date().timeIntervalSince(started),
                errorMessage: nil
            )
        } catch {
            return LocalAIJudgeResult(
                verdict: nil,
                rawOutput: "",
                elapsedSeconds: Date().timeIntervalSince(started),
                errorMessage: error.localizedDescription
            )
        }
    }

    /// Temporary Settings benchmark retained while the feature is being tuned.
    func smokeTest() -> LocalAIJudgeResult {
        engine = nil

        let cold = judge(
            language: "French",
            register: "informal everyday spoken French",
            english: "Now that is completely my thing.",
            reference: "Ça, c’est totalement mon truc.",
            learner: "Là, c’est vraiment mon truc.",
            context: ""
        )

        guard cold.errorMessage == nil, cold.verdict == "ACCEPT" else {
            engine = nil
            return cold
        }

        let warm = judge(
            language: "French",
            register: "informal everyday spoken French",
            english: "Now that is completely my thing.",
            reference: "Ça, c’est totalement mon truc.",
            learner: "Là, c’est vraiment mon truc.",
            context: ""
        )

        print(
            String(
                format: "LingoNative Qwen CPU benchmark — cold %.2fs, warm %.2fs",
                cold.elapsedSeconds,
                warm.elapsedSeconds
            )
        )

        engine = nil
        return warm
    }

    func unload() {
        engine = nil
    }

    private static func prompt(
        language: String,
        register: String,
        english: String,
        reference: String,
        learner: String,
        context: String
    ) -> String {
        let system = """
        You grade answers for Lingo Native, an everyday spoken-language app.
        The English meaning is authoritative. The reference is ONE valid translation, not wording the learner must copy.
        Judge whether the learner answer conveys the SAME meaning as the English prompt.
        ACCEPT natural synonyms, paraphrases, contractions, idioms and colloquial grammar.
        Slightly different but idiomatically equivalent emphasis or intensifiers are fine when the core claim is unchanged.
        In informal spoken French, dropping ne in negatives is normal and must be accepted.
        In informal Madrid Spanish, normal Peninsular colloquial usage is valid.
        In Lebanese Arabic, natural everyday Lebanese colloquial usage is valid.
        Context may be a broad corpus section label. Use it only when it genuinely disambiguates meaning;
        never treat its wording or theme as an extra requirement.

        Be strict about meaning. REJECT any real change in polarity, tense/aspect, modality,
        person, participant roles, possession, time, materially different degree, direction, or required information.
        Do not ACCEPT merely because the two answers are grammatical, related, or plausible.
        Ask yourself: could the learner answer replace the reference in this exact situation
        WITHOUT changing what the speaker is claiming? If not, REJECT.

        Example:
        English: I forgot.
        Reference: Se me ha olvidado.
        Learner: Me he olvidado.
        Verdict: ACCEPT

        Return exactly one word: ACCEPT or REJECT. Do not explain your answer.
        """

        let contextLine = context.isEmpty ? "(none needed)" : context

        let user = """
        Language: \(language)
        Register: \(register)
        Context: \(contextLine)
        English meaning: \(english)
        Reference translation: \(reference)
        Learner answer: \(learner)
        /no_think
        """

        return """
        <|im_start|>system
        \(system)<|im_end|>
        <|im_start|>user
        \(user)<|im_end|>
        <|im_start|>assistant
        """
    }

    private static func lastVerdict(in text: String) -> String? {
        let pattern = #"\b(ACCEPT|REJECT)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let upper = text.uppercased()
        let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
        guard let match = regex.matches(in: upper, range: range).last,
              let verdictRange = Range(match.range(at: 1), in: upper) else {
            return nil
        }

        return String(upper[verdictRange])
    }
}
