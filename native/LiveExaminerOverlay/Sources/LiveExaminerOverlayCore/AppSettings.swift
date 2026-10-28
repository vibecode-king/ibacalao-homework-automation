import Foundation
import Combine

enum LLMProvider: String, CaseIterable, Identifiable, Codable, CustomStringConvertible {
    case hosted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hosted: return "iBacalao hosted"
        }
    }

    var description: String { label }
}

/// IB subject context for tips/chat. Stored on the main app, not the overlay.
enum CoachingSubject: String, CaseIterable, Identifiable, Codable, CustomStringConvertible {
    case general
    case biology
    case chemistry
    case physics
    case mathAA
    case mathAI
    case history
    case englishLangLit
    case englishLit
    case englishB
    case spanishLangLit
    case spanishLit
    case spanishB
    case business
    case economics
    case psychology
    case ess
    case visualArts
    case globalPolitics
    case geography
    case computerScience
    case sehs
    case film
    case philosophy
    case theatre
    case music
    case sca
    case tok
    case extendedEssay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General / Other"
        case .biology: return "Biology"
        case .chemistry: return "Chemistry"
        case .physics: return "Physics"
        case .mathAA: return "Math: Analysis & Approaches"
        case .mathAI: return "Math: Applications & Interpretation"
        case .history: return "History"
        case .englishLangLit: return "English A: Lang & Lit"
        case .englishLit: return "English A: Literature"
        case .englishB: return "English B"
        case .spanishLangLit: return "Spanish A: Lang & Lit"
        case .spanishLit: return "Spanish A: Literature"
        case .spanishB: return "Spanish B"
        case .business: return "Business Management"
        case .economics: return "Economics"
        case .psychology: return "Psychology"
        case .ess: return "Environmental Systems & Societies"
        case .visualArts: return "Visual Arts"
        case .globalPolitics: return "Global Politics"
        case .geography: return "Geography"
        case .computerScience: return "Computer Science"
        case .sehs: return "Sports, Exercise & Health Science"
        case .film: return "Film"
        case .philosophy: return "Philosophy"
        case .theatre: return "Theatre"
        case .music: return "Music"
        case .sca: return "Social & Cultural Anthropology"
        case .tok: return "Theory of Knowledge"
        case .extendedEssay: return "Extended Essay"
        }
    }

    var description: String { label }

    /// Visual cue in the subject selector.
    var emoji: String {
        switch self {
        case .general: return "◎"
        case .biology: return "🧬"
        case .chemistry: return "⚗️"
        case .physics: return "⚛️"
        case .mathAA, .mathAI: return "∑"
        case .history: return "📜"
        case .englishLangLit, .englishLit, .englishB: return "🇬🇧"
        case .spanishLangLit, .spanishLit, .spanishB: return "🇪🇸"
        case .business: return "💼"
        case .economics: return "📈"
        case .psychology: return "🧠"
        case .ess: return "🌍"
        case .visualArts: return "🎨"
        case .globalPolitics: return "🏛️"
        case .geography: return "🗺️"
        case .computerScience: return "💻"
        case .sehs: return "🏃"
        case .film: return "🎬"
        case .philosophy: return "💭"
        case .theatre: return "🎭"
        case .music: return "🎵"
        case .sca: return "👥"
        case .tok: return "❓"
        case .extendedEssay: return "📝"
        }
    }

    /// Phrase injected into the LLM system prompt.
    var promptContext: String? {
        switch self {
        case .general:
            return nil
        case .tok:
            return "The student is writing IB Theory of Knowledge (TOK). Prefer TOK conventions: knowledge questions, AOKs/WOKs, and claims grounded in examples."
        case .extendedEssay:
            return "The student is writing an IB Extended Essay. Prefer EE conventions: research question focus, argument structure, and academic citation discipline."
        default:
            return "The student is writing for IB \(label). Tailor tips to that subject's expectations, vocabulary, and assessment conventions (e.g. IA / coursework)."
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let provider = "llmProvider"
        static let spokenTipsEnabled = "spokenTipsEnabled"
        static let customInstructions = "customInstructions"
        static let subject = "coachingSubject"
        static let spokenVoice = "spokenVoice"
        static let demoRecordingMode = "demoRecordingMode"
    }

    @Published var provider: LLMProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: Keys.provider) }
    }

    @Published var spokenTipsEnabled: Bool {
        didSet { UserDefaults.standard.set(spokenTipsEnabled, forKey: Keys.spokenTipsEnabled) }
    }

    /// Extra instructions appended to tip + chat system prompts.
    @Published var customInstructions: String {
        didSet { UserDefaults.standard.set(customInstructions, forKey: Keys.customInstructions) }
    }

    /// Subject selected on the main app Launch screen — gives the coach context.
    @Published var subject: CoachingSubject {
        didSet { UserDefaults.standard.set(subject.rawValue, forKey: Keys.subject) }
    }

    /// macOS `/usr/bin/say` voice name (e.g. Samantha).
    @Published var spokenVoice: String {
        didSet { UserDefaults.standard.set(spokenVoice, forKey: Keys.spokenVoice) }
    }

    /// When true, the overlay panel is visible to screen recorders (for demo/marketing
    /// capture). Default false — the overlay is invisible to screen sharing/OCR, which
    /// also prevents OCR from reading our own tip text back in as document content.
    /// No Settings UI — toggled only via `defaults write` when an admin asks.
    @Published var demoRecordingModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(demoRecordingModeEnabled, forKey: Keys.demoRecordingMode)
            AppDelegate.shared?.applyOverlaySharingType()
        }
    }

    private init() {
        provider = .hosted
        UserDefaults.standard.set(LLMProvider.hosted.rawValue, forKey: Keys.provider)
        if UserDefaults.standard.object(forKey: Keys.spokenTipsEnabled) == nil {
            spokenTipsEnabled = true
        } else {
            spokenTipsEnabled = UserDefaults.standard.bool(forKey: Keys.spokenTipsEnabled)
        }
        customInstructions = UserDefaults.standard.string(forKey: Keys.customInstructions) ?? ""
        let subjectRaw = UserDefaults.standard.string(forKey: Keys.subject) ?? CoachingSubject.general.rawValue
        subject = CoachingSubject(rawValue: subjectRaw) ?? .general
        let voice = UserDefaults.standard.string(forKey: Keys.spokenVoice)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        spokenVoice = voice.isEmpty ? "Samantha" : voice
        demoRecordingModeEnabled = UserDefaults.standard.bool(forKey: Keys.demoRecordingMode)
    }
}
