import SwiftUI
import UIKit

extension Color {
    static let lingoGreen = Color(red: 0.34, green: 0.78, blue: 0.22)
    static let lingoGreenDark = Color(red: 0.23, green: 0.62, blue: 0.15)
    static let lingoBlue = Color(red: 0.12, green: 0.64, blue: 0.90)
    static let lingoGold = Color(red: 1.00, green: 0.78, blue: 0.14)
    static let lingoInk = Color(red: 0.24, green: 0.27, blue: 0.29)
    static let lingoMuted = Color(red: 0.54, green: 0.58, blue: 0.60)
    static let lingoLine = Color(red: 0.89, green: 0.90, blue: 0.91)
    static let lingoWrong = Color(red: 0.93, green: 0.30, blue: 0.28)
    static let lingoCorrect = Color(red: 0.34, green: 0.78, blue: 0.22)
    static let lingoPurple = Color(red: 0.67, green: 0.43, blue: 0.91)
    static let lingoOrange = Color(red: 1.00, green: 0.58, blue: 0.17)
}

struct StarButton: View {
    @EnvironmentObject private var stars: StarStore

    private let key: String
    private let itemName: String

    init(course: LanguageCourse, phrase: PhraseEntry) {
        key = StarStore.phraseKey(course: course, phrase: phrase)
        itemName = "phrase"
    }

    init(course: LanguageCourse, lemma: Lemma) {
        key = StarStore.lemmaKey(course: course, lemma: lemma)
        itemName = "lemma"
    }

    init(
        course: LanguageCourse,
        lemmaForeign: String,
        lemmaEnglish: String
    ) {
        key = StarStore.lemmaKey(
            course: course,
            foreign: lemmaForeign,
            english: lemmaEnglish
        )
        itemName = "lemma"
    }

    init(course: LanguageCourse, question: QuizQuestion) {
        if question.type == .lemma {
            key = StarStore.lemmaKey(
                course: course,
                foreign: question.prompt,
                english: question.correctAnswer
            )
            itemName = "lemma"
        } else {
            key = StarStore.phraseKey(course: course, phrase: question.phrase)
            itemName = "phrase"
        }
    }

    var body: some View {
        let starred = stars.isStarred(key)

        Button {
            stars.toggle(key)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: starred ? "star.fill" : "star")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(
                    starred ? Color.lingoGold : Color.lingoMuted.opacity(0.7)
                )
                .frame(width: 40, height: 40)
                .background(Color.black.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(starred ? "Unstar \(itemName)" : "Star \(itemName)")
    }
}

