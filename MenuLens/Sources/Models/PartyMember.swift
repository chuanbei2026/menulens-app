import SwiftUI
import UIKit

/// One person at the table. Profiles are app-global (managed in Settings)
/// and referenced by the per-scan cart to record who ordered which dish.
struct PartyMember: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// DietTag raw values this person doesn't eat (optional so profiles
    /// saved before restrictions existed still decode).
    var avoids: [String]?

    var avoidedTags: Set<DietTag> {
        Set((avoids ?? []).compactMap(DietTag.init(rawValue:)))
    }
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
            members = [PartyMember(id: UUID(), name: "我", avoids: [])]
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
        members.append(PartyMember(id: UUID(), name: trimmed, avoids: []))
    }

    /// Toggle one restriction for one member.
    func toggle(_ tag: DietTag, for id: UUID) {
        guard let index = members.firstIndex(where: { $0.id == id }) else { return }
        var avoids = Set(members[index].avoids ?? [])
        if avoids.contains(tag.rawValue) { avoids.remove(tag.rawValue) } else { avoids.insert(tag.rawValue) }
        members[index].avoids = Array(avoids).sorted()
    }

    /// The last remaining member can't be removed.
    func remove(at offsets: IndexSet) {
        guard members.count > 1 else { return }
        var trimmed = members
        trimmed.remove(atOffsets: offsets)
        members = trimmed.isEmpty ? [members[0]] : trimmed
    }

    /// Remove one member directly (the ✕ button); the last one stays.
    func remove(id: UUID) {
        guard members.count > 1 else { return }
        members.removeAll { $0.id == id }
        removeAvatar(for: id)
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

    // MARK: - Avatars (Documents/avatars/<id>.jpg)

    /// Bumped whenever an avatar changes so views refresh.
    @Published private(set) var avatarVersion = 0

    private var avatarDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func avatarURL(of id: UUID) -> URL {
        avatarDirectory.appendingPathComponent("\(id.uuidString).jpg")
    }

    func avatar(of id: UUID) -> UIImage? {
        UIImage(contentsOfFile: avatarURL(of: id).path)
    }

    /// Center-crop to a square, downscale, save.
    func setAvatar(_ image: UIImage, for id: UUID) {
        let source = image.normalizedOrientation()
        let side = min(source.size.width, source.size.height)
        let crop = CGRect(
            x: (source.size.width - side) / 2,
            y: (source.size.height - side) / 2,
            width: side, height: side
        )
        guard let cg = source.cgImage?.cropping(to: crop) else { return }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200), format: format)
            .image { _ in UIImage(cgImage: cg).draw(in: CGRect(x: 0, y: 0, width: 200, height: 200)) }
        try? small.jpegData(compressionQuality: 0.85)?.write(to: avatarURL(of: id))
        avatarVersion += 1
    }

    func removeAvatar(for id: UUID) {
        try? FileManager.default.removeItem(at: avatarURL(of: id))
        avatarVersion += 1
    }
}

/// Round avatar: the member's photo if uploaded, else their color + initial.
struct AvatarView: View {
    @ObservedObject var party: PartyStore
    let memberID: UUID
    var size: CGFloat = 26

    var body: some View {
        Group {
            if let image = party.avatar(of: memberID) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(party.color(of: memberID))
                    Text(String(party.name(of: memberID).prefix(1)))
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .id(party.avatarVersion) // refresh when avatars change
    }
}
