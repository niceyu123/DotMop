import Foundation
import Observation

// Keep the scope alive while workers are still using the volume, even after the UI removes it.
final class VolumeAccess: Sendable {
    let url: URL
    let isStale: Bool

    init?(url: URL, isStale: Bool = false) {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        self.url = url
        self.isStale = isStale
    }

    deinit {
        url.stopAccessingSecurityScopedResource()
    }
}

@Observable
@MainActor
final class VolumeAuthorizationStore {
    private static let key = "externalVolumeBookmarks.v1"

    @ObservationIgnored private let defaults: UserDefaults
    private var active: [String: Entry] = [:]

    private struct Entry {
        let volume: VolumeReference
        let access: VolumeAccess
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    static func forCurrentBuild() -> VolumeAuthorizationStore? {
        #if DOTMOP_APP_STORE
        VolumeAuthorizationStore(defaults: .standard)
        #else
        nil
        #endif
    }

    static func canAuthorize(_ url: URL, as volume: VolumeReference) -> Bool {
        ScopePath.same(url, volume.url)
    }

    func access(for volume: VolumeReference) -> VolumeAccess? {
        guard let entry = active[volume.id], entry.volume == volume else { return nil }
        return entry.access
    }

    func remember(_ access: VolumeAccess, for volume: VolumeReference, persistForReconnect: Bool) throws {
        guard Self.canAuthorize(access.url, as: volume) else { throw SafetyError.outsideScope }
        _ = try VolumeBoundary(volume: volume, root: access.url)
        active[volume.id] = Entry(volume: volume, access: access)
        setWholeVolumeApproved(persistForReconnect, for: volume)
    }

    // A folder selection must not turn into an automatic whole-volume scan on reconnect.
    func setWholeVolumeApproved(_ approved: Bool, for volume: VolumeReference) {
        guard let identifier = volume.persistentID else { return }
        if approved, let access = access(for: volume) {
            saveBookmark(for: identifier, url: access.url)
        } else if !approved {
            var bookmarks = defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
            bookmarks.removeValue(forKey: identifier)
            defaults.set(bookmarks, forKey: Self.key)
        }
    }

    func remove(_ volume: VolumeReference) {
        active.removeValue(forKey: volume.id)
    }

    var activeAccess: [VolumeAccess] { active.values.map(\.access) }

    func resolveSavedAccess() -> [String: VolumeAccess] {
        let bookmarks = defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        var resolved: [String: VolumeAccess] = [:]
        for (identifier, data) in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  let access = VolumeAccess(url: url, isStale: stale) else { continue }
            resolved[identifier] = access
        }
        return resolved
    }

    func refresh(volumes: [VolumeReference], resolved: [String: VolumeAccess]) {
        active = active.filter { _, entry in volumes.contains(entry.volume) }
        for volume in volumes where access(for: volume) == nil {
            guard let identifier = volume.persistentID, let access = resolved[identifier],
                  Self.canAuthorize(access.url, as: volume),
                  (try? VolumeBoundary(volume: volume, root: access.url)) != nil else { continue }
            active[volume.id] = Entry(volume: volume, access: access)
            if access.isStale { saveBookmark(for: identifier, url: access.url) }
        }
    }

    private func saveBookmark(for identifier: String, url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var bookmarks = defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        bookmarks[identifier] = data
        defaults.set(bookmarks, forKey: Self.key)
    }
}
