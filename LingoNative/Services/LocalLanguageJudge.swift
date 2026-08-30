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


private enum SpanishSemanticLexicon {
    // Tier 1: candidate semantic equivalents.
    // These are hints for Qwen, NOT blind substitutions.
    static let equivalents: [[String]] = [
        [
                "haber",
                "existir"
        ],
        [
                "pasar",
                "ocurrir",
                "suceder"
        ],
        [
                "tener lugar",
                "ocurrir",
                "suceder"
        ],
        [
                "aparecer",
                "surgir"
        ],
        [
                "desaparecer",
                "esfumarse"
        ],
        [
                "quedar",
                "permanecer"
        ],
        [
                "seguir",
                "continuar"
        ],
        [
                "empezar",
                "comenzar"
        ],
        [
                "arrancar",
                "empezar"
        ],
        [
                "iniciar",
                "empezar"
        ],
        [
                "terminar",
                "acabar"
        ],
        [
                "finalizar",
                "terminar"
        ],
        [
                "dejar de",
                "parar de"
        ],
        [
                "parar",
                "detenerse"
        ],
        [
                "cesar",
                "parar"
        ],
        [
                "hacer",
                "realizar"
        ],
        [
                "hacer",
                "llevar a cabo"
        ],
        [
                "preparar",
                "hacer"
        ],
        [
                "montar",
                "organizar"
        ],
        [
                "organizar",
                "preparar"
        ],
        [
                "crear",
                "hacer"
        ],
        [
                "fabricar",
                "hacer"
        ],
        [
                "conseguir",
                "lograr"
        ],
        [
                "conseguir",
                "obtener"
        ],
        [
                "obtener",
                "lograr"
        ],
        [
                "alcanzar",
                "lograr"
        ],
        [
                "sacar",
                "obtener"
        ],
        [
                "ganarse",
                "conseguir"
        ],
        [
                "intentar",
                "tratar de"
        ],
        [
                "probar",
                "intentar"
        ],
        [
                "hacer el intento",
                "intentarlo"
        ],
        [
                "querer",
                "tener ganas de"
        ],
        [
                "apetecer",
                "tener ganas de"
        ],
        [
                "preferir",
                "gustar más"
        ],
        [
                "encantar",
                "gustar muchísimo"
        ],
        [
                "gustar",
                "agradar"
        ],
        [
                "no gustar",
                "desagradar"
        ],
        [
                "necesitar",
                "hacer falta"
        ],
        [
                "hacer falta",
                "ser necesario"
        ],
        [
                "tener que",
                "deber"
        ],
        [
                "deber",
                "haber que"
        ],
        [
                "poder",
                "ser capaz de"
        ],
        [
                "saber",
                "saber cómo"
        ],
        [
                "conseguir",
                "poder"
        ],
        [
                "decidir",
                "tomar una decisión"
        ],
        [
                "elegir",
                "escoger"
        ],
        [
                "optar por",
                "elegir"
        ],
        [
                "quedarse con",
                "elegir"
        ],
        [
                "pensar",
                "creer"
        ],
        [
                "opinar",
                "pensar"
        ],
        [
                "considerar",
                "pensar"
        ],
        [
                "parecer",
                "dar la impresión"
        ],
        [
                "me parece",
                "creo que"
        ],
        [
                "diría que",
                "creo que"
        ],
        [
                "supongo",
                "imagino"
        ],
        [
                "imaginar",
                "suponer"
        ],
        [
                "dudar",
                "no estar seguro"
        ],
        [
                "estar seguro",
                "tener claro"
        ],
        [
                "saber",
                "conocer"
        ],
        [
                "entender",
                "comprender"
        ],
        [
                "darse cuenta",
                "percatarse"
        ],
        [
                "enterarse",
                "saber"
        ],
        [
                "averiguar",
                "descubrir"
        ],
        [
                "descubrir",
                "enterarse de"
        ],
        [
                "recordar",
                "acordarse de"
        ],
        [
                "olvidar",
                "olvidarse de"
        ],
        [
                "decir",
                "comentar"
        ],
        [
                "contar",
                "decir"
        ],
        [
                "explicar",
                "contar"
        ],
        [
                "mencionar",
                "nombrar"
        ],
        [
                "hablar",
                "charlar"
        ],
        [
                "charlar",
                "conversar"
        ],
        [
                "preguntar",
                "hacer una pregunta"
        ],
        [
                "responder",
                "contestar"
        ],
        [
                "repetir",
                "volver a decir"
        ],
        [
                "avisar",
                "advertir"
        ],
        [
                "informar",
                "avisar"
        ],
        [
                "aclarar",
                "explicar"
        ],
        [
                "pedir",
                "solicitar"
        ],
        [
                "pedir",
                "encargar"
        ],
        [
                "preguntar por",
                "consultar"
        ],
        [
                "pedir ayuda",
                "solicitar ayuda"
        ],
        [
                "dar",
                "entregar"
        ],
        [
                "dar",
                "ofrecer"
        ],
        [
                "regalar",
                "dar"
        ],
        [
                "prestar",
                "dejar"
        ],
        [
                "devolver",
                "retornar"
        ],
        [
                "llevar",
                "traer"
        ],
        [
                "coger",
                "agarrar"
        ],
        [
                "coger",
                "tomar"
        ],
        [
                "recoger",
                "ir a buscar"
        ],
        [
                "traer",
                "llevar hasta aquí"
        ],
        [
                "llevar",
                "transportar"
        ],
        [
                "poner",
                "colocar"
        ],
        [
                "meter",
                "introducir"
        ],
        [
                "sacar",
                "extraer"
        ],
        [
                "guardar",
                "meter"
        ],
        [
                "dejar",
                "poner"
        ],
        [
                "quitar",
                "retirar"
        ],
        [
                "buscar",
                "tratar de encontrar"
        ],
        [
                "encontrar",
                "hallar"
        ],
        [
                "localizar",
                "encontrar"
        ],
        [
                "mirar",
                "ver"
        ],
        [
                "observar",
                "mirar"
        ],
        [
                "echar un vistazo",
                "mirar"
        ],
        [
                "fijarse",
                "prestar atención"
        ],
        [
                "ver",
                "notar"
        ],
        [
                "notar",
                "darse cuenta de"
        ],
        [
                "percibir",
                "notar"
        ],
        [
                "reconocer",
                "identificar"
        ],
        [
                "ir",
                "marcharse"
        ],
        [
                "irse",
                "marcharse"
        ],
        [
                "venir",
                "acercarse"
        ],
        [
                "llegar",
                "venir"
        ],
        [
                "volver",
                "regresar"
        ],
        [
                "regresar",
                "volver"
        ],
        [
                "pasarse",
                "venir"
        ],
        [
                "acercarse",
                "venir"
        ],
        [
                "salir",
                "marcharse"
        ],
        [
                "entrar",
                "meterse"
        ],
        [
                "salir",
                "irse"
        ],
        [
                "irse de",
                "salir de"
        ],
        [
                "abandonar",
                "irse de"
        ],
        [
                "moverse",
                "desplazarse"
        ],
        [
                "viajar",
                "desplazarse"
        ],
        [
                "andar",
                "caminar"
        ],
        [
                "caminar",
                "ir andando"
        ],
        [
                "ir a pie",
                "ir andando"
        ],
        [
                "conducir",
                "manejar"
        ],
        [
                "coger el metro",
                "ir en metro"
        ],
        [
                "coger el autobús",
                "ir en autobús"
        ],
        [
                "vivir",
                "residir"
        ],
        [
                "quedarse",
                "alojarse"
        ],
        [
                "alojarse",
                "hospedarse"
        ],
        [
                "estar",
                "quedarse"
        ],
        [
                "trabajar",
                "currar"
        ],
        [
                "trabajo",
                "curro"
        ],
        [
                "empleo",
                "trabajo"
        ],
        [
                "jefe",
                "responsable"
        ],
        [
                "compañero",
                "colega"
        ],
        [
                "despedir",
                "echar"
        ],
        [
                "renunciar",
                "dimitir"
        ],
        [
                "dejar el trabajo",
                "renunciar"
        ],
        [
                "comprar",
                "adquirir"
        ],
        [
                "vender",
                "poner a la venta"
        ],
        [
                "pagar",
                "abonar"
        ],
        [
                "cobrar",
                "recibir el pago"
        ],
        [
                "costar",
                "valer"
        ],
        [
                "valer",
                "costar"
        ],
        [
                "gastar",
                "gastarse"
        ],
        [
                "ahorrar",
                "guardar dinero"
        ],
        [
                "tienda",
                "comercio"
        ],
        [
                "supermercado",
                "súper"
        ],
        [
                "rebaja",
                "descuento"
        ],
        [
                "oferta",
                "promoción"
        ],
        [
                "devolver",
                "hacer una devolución"
        ],
        [
                "cambiar",
                "hacer un cambio"
        ],
        [
                "probarse",
                "probar"
        ],
        [
                "comer",
                "tomar"
        ],
        [
                "beber",
                "tomar"
        ],
        [
                "desayunar",
                "tomar el desayuno"
        ],
        [
                "cenar",
                "tomar la cena"
        ],
        [
                "cocinar",
                "preparar comida"
        ],
        [
                "preparar",
                "hacer"
        ],
        [
                "calentar",
                "recalentar"
        ],
        [
                "enfriar",
                "dejar enfriar"
        ],
        [
                "sabor",
                "gusto"
        ],
        [
                "rico",
                "bueno"
        ],
        [
                "riquísimo",
                "buenísimo"
        ],
        [
                "delicioso",
                "riquísimo"
        ],
        [
                "casa",
                "hogar"
        ],
        [
                "piso",
                "apartamento"
        ],
        [
                "habitación",
                "cuarto"
        ],
        [
                "salón",
                "sala de estar"
        ],
        [
                "ordenar",
                "recoger"
        ],
        [
                "limpiar",
                "asear"
        ],
        [
                "ensuciar",
                "manchar"
        ],
        [
                "arreglar",
                "reparar"
        ],
        [
                "estropearse",
                "romperse"
        ],
        [
                "ropa",
                "prendas"
        ],
        [
                "ponerse",
                "vestirse con"
        ],
        [
                "quitarse",
                "sacarse"
        ],
        [
                "quedar bien",
                "sentar bien"
        ],
        [
                "quedar mal",
                "sentar mal"
        ],
        [
                "pegar",
                "combinar"
        ],
        [
                "combinar",
                "hacer juego"
        ],
        [
                "estar de moda",
                "llevarse"
        ],
        [
                "pasado de moda",
                "anticuado"
        ],
        [
                "guapo",
                "atractivo"
        ],
        [
                "bonito",
                "precioso"
        ],
        [
                "precioso",
                "muy bonito"
        ],
        [
                "feo",
                "poco atractivo"
        ],
        [
                "arreglado",
                "bien vestido"
        ],
        [
                "elegante",
                "arreglado"
        ],
        [
                "feliz",
                "contento"
        ],
        [
                "contento",
                "alegre"
        ],
        [
                "triste",
                "deprimido"
        ],
        [
                "enfadado",
                "cabreado"
        ],
        [
                "molesto",
                "enfadado"
        ],
        [
                "nervioso",
                "ansioso"
        ],
        [
                "preocupado",
                "inquieto"
        ],
        [
                "asustado",
                "con miedo"
        ],
        [
                "tener miedo",
                "estar asustado"
        ],
        [
                "cansado",
                "agotado"
        ],
        [
                "agotado",
                "reventado"
        ],
        [
                "aburrido",
                "harto"
        ],
        [
                "emocionado",
                "ilusionado"
        ],
        [
                "ilusionado",
                "con ganas"
        ],
        [
                "tranquilo",
                "relajado"
        ],
        [
                "relajarse",
                "tranquilizarse"
        ],
        [
                "calmarse",
                "tranquilizarse"
        ],
        [
                "estar malo",
                "estar enfermo"
        ],
        [
                "ponerse malo",
                "enfermar"
        ],
        [
                "me duele",
                "tengo dolor de"
        ],
        [
                "dolor",
                "molestia"
        ],
        [
                "mareado",
                "con mareo"
        ],
        [
                "catarro",
                "resfriado"
        ],
        [
                "medicamento",
                "medicina"
        ],
        [
                "médico",
                "doctor"
        ],
        [
                "cita",
                "consulta"
        ],
        [
                "fácil",
                "sencillo"
        ],
        [
                "difícil",
                "complicado"
        ],
        [
                "complicado",
                "difícil"
        ],
        [
                "simple",
                "sencillo"
        ],
        [
                "lioso",
                "complicado"
        ],
        [
                "bueno",
                "estupendo"
        ],
        [
                "genial",
                "estupendo"
        ],
        [
                "fantástico",
                "genial"
        ],
        [
                "perfecto",
                "ideal"
        ],
        [
                "malo",
                "terrible"
        ],
        [
                "horrible",
                "fatal"
        ],
        [
                "fatal",
                "muy mal"
        ],
        [
                "regular",
                "así así"
        ],
        [
                "grande",
                "enorme"
        ],
        [
                "enorme",
                "gigante"
        ],
        [
                "pequeño",
                "chico"
        ],
        [
                "minúsculo",
                "muy pequeño"
        ],
        [
                "rápido",
                "veloz"
        ],
        [
                "deprisa",
                "rápido"
        ],
        [
                "lentamente",
                "despacio"
        ],
        [
                "lento",
                "pausado"
        ],
        [
                "cerca",
                "al lado"
        ],
        [
                "cerca de",
                "próximo a"
        ],
        [
                "lejos",
                "a distancia"
        ],
        [
                "al lado",
                "junto a"
        ],
        [
                "lleno",
                "a tope"
        ],
        [
                "vacío",
                "sin nada"
        ],
        [
                "abarrotado",
                "lleno"
        ],
        [
                "petado",
                "lleno"
        ],
        [
                "muchos",
                "un montón de"
        ],
        [
                "muchísimo",
                "un montón"
        ],
        [
                "pocos",
                "no muchos"
        ],
        [
                "bastantes",
                "unos cuantos"
        ],
        [
                "unos cuantos",
                "varios"
        ],
        [
                "a veces",
                "de vez en cuando"
        ],
        [
                "de vez en cuando",
                "alguna vez"
        ],
        [
                "normalmente",
                "por lo general"
        ],
        [
                "generalmente",
                "normalmente"
        ],
        [
                "a menudo",
                "frecuentemente"
        ],
        [
                "muchas veces",
                "a menudo"
        ],
        [
                "siempre",
                "todo el rato"
        ],
        [
                "nunca",
                "jamás"
        ],
        [
                "ahora",
                "ahora mismo"
        ],
        [
                "enseguida",
                "ahora mismo"
        ],
        [
                "luego",
                "más tarde"
        ],
        [
                "después",
                "más tarde"
        ],
        [
                "antes",
                "previamente"
        ],
        [
                "hace poco",
                "recientemente"
        ],
        [
                "otra vez",
                "de nuevo"
        ],
        [
                "volver a",
                "hacer otra vez"
        ],
        [
                "quizá",
                "quizás"
        ],
        [
                "a lo mejor",
                "quizá"
        ],
        [
                "puede que",
                "a lo mejor"
        ],
        [
                "igual",
                "a lo mejor"
        ],
        [
                "muy",
                "súper"
        ],
        [
                "muy",
                "realmente"
        ],
        [
                "realmente",
                "de verdad"
        ],
        [
                "de verdad",
                "en serio"
        ],
        [
                "totalmente",
                "completamente"
        ],
        [
                "completamente",
                "del todo"
        ],
        [
                "exactamente",
                "justo"
        ],
        [
                "más o menos",
                "aproximadamente"
        ],
        [
                "aproximadamente",
                "alrededor de"
        ],
        [
                "casi",
                "prácticamente"
        ],
        [
                "también",
                "además"
        ],
        [
                "además",
                "encima"
        ],
        [
                "tampoco",
                "ni tampoco"
        ],
        [
                "pero",
                "aunque"
        ],
        [
                "sin embargo",
                "pero"
        ],
        [
                "aun así",
                "sin embargo"
        ],
        [
                "de todas formas",
                "de todos modos"
        ],
        [
                "porque",
                "ya que"
        ],
        [
                "como",
                "puesto que"
        ],
        [
                "por eso",
                "por ese motivo"
        ],
        [
                "así que",
                "por eso"
        ],
        [
                "vale",
                "de acuerdo"
        ],
        [
                "de acuerdo",
                "está bien"
        ],
        [
                "claro",
                "por supuesto"
        ],
        [
                "desde luego",
                "por supuesto"
        ],
        [
                "exacto",
                "eso es"
        ],
        [
                "totalmente",
                "desde luego"
        ],
        [
                "no estoy de acuerdo",
                "no lo veo así"
        ],
        [
                "no me convence",
                "no lo veo"
        ],
        [
                "ni de broma",
                "de ninguna manera"
        ],
        [
                "para nada",
                "en absoluto"
        ],
        [
                "seguro",
                "sin duda"
        ],
        [
                "sin duda",
                "desde luego"
        ],
        [
                "obviamente",
                "evidentemente"
        ],
        [
                "está claro",
                "es evidente"
        ],
        [
                "qué raro",
                "qué extraño"
        ],
        [
                "qué fuerte",
                "madre mía"
        ],
        [
                "no me digas",
                "en serio"
        ],
        [
                "anda",
                "vaya"
        ],
        [
                "me encanta",
                "me flipa"
        ],
        [
                "me gusta mucho",
                "me encanta"
        ],
        [
                "me mola",
                "me gusta"
        ],
        [
                "no me gusta nada",
                "lo odio"
        ],
        [
                "no lo soporto",
                "lo odio"
        ],
        [
                "me da igual",
                "me es indiferente"
        ],
        [
                "importante",
                "fundamental"
        ],
        [
                "esencial",
                "fundamental"
        ],
        [
                "necesario",
                "imprescindible"
        ],
        [
                "da igual",
                "no importa"
        ],
        [
                "problema",
                "inconveniente"
        ],
        [
                "problema",
                "lío"
        ],
        [
                "lío",
                "jaleo"
        ],
        [
                "fallo",
                "error"
        ],
        [
                "equivocarse",
                "cometer un error"
        ],
        [
                "arreglar",
                "solucionar"
        ],
        [
                "resolver",
                "solucionar"
        ],
        [
                "ayudar",
                "echar una mano"
        ],
        [
                "echar una mano",
                "ayudar"
        ],
        [
                "apoyar",
                "respaldar"
        ],
        [
                "esperar",
                "aguardar"
        ],
        [
                "espera",
                "un momento"
        ],
        [
                "un segundo",
                "un momento"
        ],
        [
                "date prisa",
                "apúrate"
        ],
        [
                "rápido",
                "deprisa"
        ],
        [
                "quedar",
                "verse"
        ],
        [
                "ver a alguien",
                "quedar con alguien"
        ],
        [
                "conocer a alguien",
                "presentarse"
        ],
        [
                "reunirse",
                "quedar"
        ],
        [
                "salir",
                "ir de fiesta"
        ],
        [
                "tomar algo",
                "quedar para tomar algo"
        ],
        [
                "amigo",
                "colega"
        ],
        [
                "colega",
                "amigo"
        ],
        [
                "pareja",
                "novio"
        ],
        [
                "pareja",
                "novia"
        ],
        [
                "niño",
                "peque"
        ],
        [
                "niña",
                "peque"
        ],
        [
                "hijo",
                "niño"
        ],
        [
                "padres",
                "padre y madre"
        ],
        [
                "abuelos",
                "abuelo y abuela"
        ],
        [
                "hace frío",
                "está frío"
        ],
        [
                "hace calor",
                "está haciendo calor"
        ],
        [
                "llueve",
                "está lloviendo"
        ],
        [
                "hace sol",
                "está soleado"
        ],
        [
                "está nublado",
                "hay nubes"
        ],
        [
                "hace viento",
                "hay viento"
        ],
        [
                "tarde",
                "con retraso"
        ],
        [
                "retrasarse",
                "llegar tarde"
        ],
        [
                "puntual",
                "a tiempo"
        ],
        [
                "a tiempo",
                "con tiempo"
        ],
        [
                "estar libre",
                "estar disponible"
        ],
        [
                "estar ocupado",
                "tener cosas que hacer"
        ],
        [
                "tener tiempo",
                "estar libre"
        ],
        [
                "caro",
                "costoso"
        ],
        [
                "barato",
                "económico"
        ],
        [
                "gratis",
                "gratuito"
        ],
        [
                "rebajado",
                "con descuento"
        ],
        [
                "nuevo",
                "a estrenar"
        ],
        [
                "usado",
                "de segunda mano"
        ],
        [
                "roto",
                "estropeado"
        ],
        [
                "en buen estado",
                "bien conservado"
        ],
        [
                "dinero",
                "pasta"
        ],
        [
                "cosa",
                "tema"
        ],
        [
                "problema",
                "movida"
        ],
        [
                "fiesta",
                "juerga"
        ],
        [
                "cansado",
                "hecho polvo"
        ],
        [
                "mucho trabajo",
                "un montón de curro"
        ],
        [
                "muy bueno",
                "brutal"
        ],
        [
                "muy bueno",
                "increíble"
        ],
        [
                "muy bonito",
                "una pasada"
        ],
        [
                "muy impresionante",
                "una pasada"
        ],
        [
                "estar lleno",
                "estar a tope"
        ],
        [
                "estar muy ocupado",
                "estar a tope"
        ],
        [
                "irse",
                "pirarse"
        ],
        [
                "irse",
                "largarse"
        ],
        [
                "quedarse",
                "plantarse"
        ],
        [
                "entender",
                "pillar"
        ],
        [
                "darse cuenta",
                "caer en la cuenta"
        ],
        [
                "enfadarse",
                "cabrearse"
        ],
        [
                "molestar",
                "fastidiar"
        ],
        [
                "estropear",
                "fastidiar"
        ],
        [
                "engañar",
                "timar"
        ],
        [
                "mentir",
                "decir una mentira"
        ]
]

    // Tier 2: contextual near-synonyms.
    // These are NEVER automatic equivalence.
    static let contextual: [[String]] = [
        [
                "poner",
                "dejar"
        ],
        [
                "poner",
                "meter"
        ],
        [
                "llevar",
                "traer"
        ],
        [
                "ir",
                "venir"
        ],
        [
                "mirar",
                "ver"
        ],
        [
                "oír",
                "escuchar"
        ],
        [
                "saber",
                "conocer"
        ],
        [
                "pedir",
                "preguntar"
        ],
        [
                "decir",
                "contar"
        ],
        [
                "hablar",
                "decir"
        ],
        [
                "pensar",
                "creer"
        ],
        [
                "pensar",
                "opinar"
        ],
        [
                "creer",
                "suponer"
        ],
        [
                "imaginar",
                "pensar"
        ],
        [
                "parecer",
                "ser"
        ],
        [
                "quedar",
                "estar"
        ],
        [
                "ser",
                "estar"
        ],
        [
                "tener",
                "llevar"
        ],
        [
                "hacer",
                "poner"
        ],
        [
                "quitar",
                "sacar"
        ],
        [
                "dejar",
                "permitir"
        ],
        [
                "dejar",
                "abandonar"
        ],
        [
                "volver",
                "regresar"
        ],
        [
                "volver",
                "venir otra vez"
        ],
        [
                "quedarse",
                "seguir"
        ],
        [
                "parar",
                "dejar"
        ],
        [
                "terminar",
                "dejar"
        ],
        [
                "probar",
                "intentar"
        ],
        [
                "probar",
                "comprobar"
        ],
        [
                "conseguir",
                "ganar"
        ],
        [
                "ganar",
                "obtener"
        ],
        [
                "perder",
                "dejar"
        ],
        [
                "faltar",
                "perder"
        ],
        [
                "pasar",
                "estar"
        ],
        [
                "pasar",
                "cruzar"
        ],
        [
                "pasar",
                "ocurrir"
        ],
        [
                "salir",
                "resultar"
        ],
        [
                "salir",
                "irse"
        ],
        [
                "salir",
                "aparecer"
        ],
        [
                "entrar",
                "caber"
        ],
        [
                "entrar",
                "meterse"
        ],
        [
                "tocar",
                "corresponder"
        ],
        [
                "tocar",
                "tener que"
        ],
        [
                "quedar",
                "sentar"
        ],
        [
                "sentar",
                "quedar"
        ],
        [
                "funcionar",
                "ir"
        ],
        [
                "ir bien",
                "funcionar"
        ],
        [
                "venir bien",
                "ser útil"
        ],
        [
                "servir",
                "valer"
        ],
        [
                "valer",
                "servir"
        ],
        [
                "valer",
                "costar"
        ],
        [
                "dar",
                "producir"
        ],
        [
                "dar",
                "causar"
        ],
        [
                "hacer ilusión",
                "apetecer"
        ],
        [
                "apetecer",
                "gustar"
        ],
        [
                "gustar",
                "encantar"
        ],
        [
                "molestar",
                "fastidiar"
        ],
        [
                "molestar",
                "incomodar"
        ],
        [
                "preocupar",
                "inquietar"
        ],
        [
                "dar miedo",
                "asustar"
        ],
        [
                "dar vergüenza",
                "avergonzar"
        ],
        [
                "dar pena",
                "entristecer"
        ],
        [
                "dar rabia",
                "enfadar"
        ],
        [
                "dar igual",
                "no importar"
        ],
        [
                "estar harto",
                "estar cansado de"
        ],
        [
                "estar hecho polvo",
                "estar agotado"
        ],
        [
                "estar fatal",
                "estar muy mal"
        ],
        [
                "estar genial",
                "estar muy bien"
        ],
        [
                "estar bien",
                "estar correcto"
        ],
        [
                "estar mal",
                "estar equivocado"
        ],
        [
                "raro",
                "extraño"
        ],
        [
                "raro",
                "poco habitual"
        ],
        [
                "normal",
                "habitual"
        ],
        [
                "normal",
                "corriente"
        ],
        [
                "bueno",
                "útil"
        ],
        [
                "bueno",
                "agradable"
        ],
        [
                "malo",
                "perjudicial"
        ],
        [
                "malo",
                "desagradable"
        ],
        [
                "fuerte",
                "intenso"
        ],
        [
                "fuerte",
                "grave"
        ],
        [
                "ligero",
                "suave"
        ],
        [
                "serio",
                "grave"
        ],
        [
                "serio",
                "formal"
        ],
        [
                "simple",
                "fácil"
        ],
        [
                "difícil",
                "duro"
        ],
        [
                "duro",
                "difícil"
        ],
        [
                "duro",
                "fuerte"
        ],
        [
                "grande",
                "importante"
        ],
        [
                "pequeño",
                "menor"
        ],
        [
                "nuevo",
                "reciente"
        ],
        [
                "viejo",
                "antiguo"
        ],
        [
                "viejo",
                "mayor"
        ],
        [
                "bonito",
                "mono"
        ],
        [
                "bonito",
                "guapo"
        ],
        [
                "guapo",
                "atractivo"
        ],
        [
                "elegante",
                "formal"
        ],
        [
                "cómodo",
                "práctico"
        ],
        [
                "práctico",
                "útil"
        ],
        [
                "barato",
                "asequible"
        ],
        [
                "caro",
                "costoso"
        ],
        [
                "lleno",
                "ocupado"
        ],
        [
                "vacío",
                "libre"
        ],
        [
                "rápido",
                "ágil"
        ],
        [
                "lento",
                "pesado"
        ],
        [
                "pesado",
                "molesto"
        ],
        [
                "pesado",
                "aburrido"
        ],
        [
                "divertido",
                "entretenido"
        ],
        [
                "interesante",
                "entretenido"
        ],
        [
                "aburrido",
                "soso"
        ],
        [
                "raro",
                "curioso"
        ],
        [
                "curioso",
                "interesante"
        ],
        [
                "importante",
                "serio"
        ],
        [
                "urgente",
                "importante"
        ],
        [
                "necesario",
                "útil"
        ],
        [
                "posible",
                "viable"
        ],
        [
                "imposible",
                "inviable"
        ],
        [
                "seguro",
                "fiable"
        ],
        [
                "fiable",
                "de confianza"
        ],
        [
                "exacto",
                "preciso"
        ],
        [
                "aproximado",
                "orientativo"
        ],
        [
                "casi",
                "prácticamente"
        ],
        [
                "bastante",
                "muy"
        ],
        [
                "bastante",
                "suficiente"
        ],
        [
                "demasiado",
                "muy"
        ],
        [
                "poco",
                "algo"
        ],
        [
                "un poco",
                "algo"
        ],
        [
                "algo",
                "un poco"
        ],
        [
                "entonces",
                "así que"
        ],
        [
                "entonces",
                "luego"
        ],
        [
                "luego",
                "después"
        ],
        [
                "ya",
                "ahora"
        ],
        [
                "ya",
                "todavía"
        ],
        [
                "todavía",
                "aún"
        ],
        [
                "solo",
                "solamente"
        ],
        [
                "incluso",
                "hasta"
        ],
        [
                "además",
                "también"
        ],
        [
                "encima",
                "además"
        ],
        [
                "aunque",
                "pero"
        ],
        [
                "pero",
                "sin embargo"
        ],
        [
                "porque",
                "como"
        ],
        [
                "por eso",
                "así que"
        ],
        [
                "quizá",
                "igual"
        ],
        [
                "igual",
                "puede que"
        ],
        [
                "seguramente",
                "probablemente"
        ],
        [
                "probablemente",
                "posiblemente"
        ],
        [
                "claro",
                "obviamente"
        ],
        [
                "claro",
                "sí"
        ],
        [
                "vale",
                "bueno"
        ],
        [
                "bueno",
                "pues"
        ],
        [
                "pues",
                "entonces"
        ],
        [
                "venga",
                "vale"
        ],
        [
                "venga",
                "vamos"
        ],
        [
                "anda",
                "venga"
        ],
        [
                "oye",
                "mira"
        ],
        [
                "mira",
                "oye"
        ],
        [
                "perdona",
                "disculpa"
        ],
        [
                "perdón",
                "lo siento"
        ],
        [
                "lo siento",
                "perdona"
        ],
        [
                "gracias",
                "te lo agradezco"
        ],
        [
                "no pasa nada",
                "da igual"
        ],
        [
                "no pasa nada",
                "tranquilo"
        ],
        [
                "tranquilo",
                "no te preocupes"
        ],
        [
                "qué pena",
                "qué lástima"
        ],
        [
                "qué bien",
                "genial"
        ],
        [
                "qué mal",
                "qué pena"
        ],
        [
                "qué raro",
                "qué curioso"
        ],
        [
                "qué fuerte",
                "qué locura"
        ],
        [
                "qué pasada",
                "increíble"
        ],
        [
                "una pasada",
                "impresionante"
        ],
        [
                "una maravilla",
                "una pasada"
        ],
        [
                "una preciosidad",
                "muy bonito"
        ],
        [
                "me da cosa",
                "me incomoda"
        ],
        [
                "me da palo",
                "no me apetece"
        ],
        [
                "me da pereza",
                "no me apetece"
        ],
        [
                "me da rabia",
                "me molesta"
        ],
        [
                "me da miedo",
                "me asusta"
        ],
        [
                "me da vergüenza",
                "me corta"
        ],
        [
                "me da igual",
                "me importa poco"
        ],
        [
                "me viene bien",
                "me conviene"
        ],
        [
                "me viene mal",
                "no me conviene"
        ],
        [
                "me cuadra",
                "me encaja"
        ],
        [
                "me encaja",
                "me parece bien"
        ],
        [
                "me convence",
                "me parece bien"
        ],
        [
                "no me cuadra",
                "no me encaja"
        ],
        [
                "no me convence",
                "no me parece bien"
        ],
        [
                "tener sentido",
                "cuadrar"
        ],
        [
                "no tener sentido",
                "no cuadrar"
        ],
        [
                "estar a punto de",
                "ir a"
        ],
        [
                "acabar de",
                "hacer hace poco"
        ],
        [
                "seguir haciendo",
                "continuar haciendo"
        ],
        [
                "volver a hacer",
                "hacer otra vez"
        ],
        [
                "dejar de hacer",
                "parar de hacer"
        ]
]

    static func promptHints(reference: String, learner: String) -> String {
        let referenceKey = normalized(reference)
        let learnerKey = normalized(learner)

        let equivalentHits = relevantGroups(
            equivalents,
            reference: referenceKey,
            learner: learnerKey,
            limit: 6
        )

        let contextualHits = relevantGroups(
            contextual,
            reference: referenceKey,
            learner: learnerKey,
            limit: 4
        )

        guard !equivalentHits.isEmpty || !contextualHits.isEmpty else {
            return "(none)"
        }

        var lines: [String] = []

        if !equivalentHits.isEmpty {
            lines.append(
                "Candidate equivalent groups (still preserve tense/person/roles): "
                + equivalentHits.map { $0.joined(separator: " = ") }.joined(separator: "; ")
            )
        }

        if !contextualHits.isEmpty {
            lines.append(
                "Context-sensitive near-synonyms (DO NOT auto-accept): "
                + contextualHits.map { $0.joined(separator: " ~ ") }.joined(separator: "; ")
            )
        }

        return lines.joined(separator: "\n")
    }

    private static func relevantGroups(
        _ groups: [[String]],
        reference: String,
        learner: String,
        limit: Int
    ) -> [[String]] {
        var scored: [(score: Int, group: [String])] = []

        for group in groups {
            let referenceHits = group.filter {
                containsPhrase(reference, phrase: normalized($0))
            }
            let learnerHits = group.filter {
                containsPhrase(learner, phrase: normalized($0))
            }

            guard !referenceHits.isEmpty, !learnerHits.isEmpty else {
                continue
            }

            let distinct = Set(referenceHits).union(learnerHits).count
            guard distinct >= 2 else { continue }

            let longest = group.map { normalized($0).count }.max() ?? 0
            scored.append((score: distinct * 100 + longest, group: group))
        }

        return scored
            .sorted { left, right in
                if left.score != right.score {
                    return left.score > right.score
                }
                return left.group.joined() < right.group.joined()
            }
            .prefix(limit)
            .map(\.group)
    }

    private static func containsPhrase(_ text: String, phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        return (" " + text + " ").contains(" " + phrase + " ")
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .folding(
                options: [.diacriticInsensitive],
                locale: Locale(identifier: "es_ES")
            )
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(
                of: "[^a-zñ0-9]+",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        For Spanish, a small local semantic-hint line may be supplied. Treat "=" groups as strong
        evidence only when the full sentence preserves meaning, tense, person and roles.
        Treat "~" groups as context-sensitive possibilities, NEVER as automatic equivalence.
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
        let spanishSemanticHints =
            language.localizedCaseInsensitiveContains("Spanish")
                ? SpanishSemanticLexicon.promptHints(
                    reference: reference,
                    learner: learner
                )
                : "(none)"

        let user = """
        Language: \(language)
        Register: \(register)
        Context: \(contextLine)
        Spanish semantic hints: \(spanishSemanticHints)
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
