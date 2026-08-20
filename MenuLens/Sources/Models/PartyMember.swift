import SwiftUI

/// One person at the table. Profiles are app-global (managed in Settings)
/// and referenced by the per-scan cart to record who ordered which dish.
struct PartyMember: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
}

/// Persistent list of party members. Always contains at least one member;
/// a fresh install starts with just "我".
@MainActor
final class PartyStore: ObservableObject {
    static let shared = PartyStore()

    @Published var members: [PartyMember] {
        didSet { save() }
    }

    private static let defaultsKey = "party_members"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([PartyMember].self, from: data),
           !decoded.isEmpty {
            members = decoded
        } else {
            members = [PartyMember(id: UUID(), name: "我")]
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(members) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func add(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        members.append(PartyMember(id: UUID(), name: trimmed))
    }

    /// The last remaining member can't be removed.
    func remove(at offsets: IndexSet) {
        guard members.count > 1 else { return }
        var trimmed = members
        trimmed.remove(atOffsets: offsets)
        members = trimmed.isEmpty ? [members[0]] : trimmed
    }

    func name(of id: UUID) -> String {
        members.first { $0.id == id }?.name ?? "?"
    }

    /// Stable accent color per member (by position).
    func color(of id: UUID) -> Color {
        let palette: [Color] = [.orange, .blue, .green, .purple, .pink, .teal, .red, .indigo]
        let index = members.firstIndex { $0.id == id } ?? 0
        return palette[index % palette.count]
    }
}
