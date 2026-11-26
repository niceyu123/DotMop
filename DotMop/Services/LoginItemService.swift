import Foundation
import Observation
import ServiceManagement
import SwiftUI

@Observable
@MainActor
final class LoginItemService {
    enum State: Equatable {
        case notRegistered, enabled, requiresApproval, notFound, unknown

        init(_ status: SMAppService.Status) {
            switch status {
            case .notRegistered: self = .notRegistered
            case .enabled: self = .enabled
            case .requiresApproval: self = .requiresApproval
            case .notFound: self = .notFound
            @unknown default: self = .unknown
            }
        }

        var label: LocalizedStringKey {
            switch self {
            case .notRegistered: "未启用"
            case .enabled: "已启用"
            case .requiresApproval: "等待系统批准"
            case .notFound: "系统找不到此登录项"
            case .unknown: "系统返回了未知状态"
            }
        }
    }

    struct Backend {
        let status: @MainActor () -> State
        let register: @MainActor () throws -> Void
        let unregister: @MainActor () async throws -> Void

        @MainActor static let system = Backend(
            status: { State(SMAppService.mainApp.status) },
            register: { try SMAppService.mainApp.register() },
            unregister: { try await SMAppService.mainApp.unregister() }
        )
    }

    @ObservationIgnored private let backend: Backend
    private(set) var state: State
    private(set) var isUpdating = false
    private(set) var errorMessage: String?
    var isEnabled: Bool { state == .enabled }

    init(backend: Backend = .system) {
        self.backend = backend
        state = backend.status()
    }

    func refresh() {
        state = backend.status()
        if isEnabled { errorMessage = nil }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        refresh()
        if enabled && (isEnabled || state == .requiresApproval) { return }
        if !enabled && state == .notRegistered { return }

        isUpdating = true
        errorMessage = nil
        defer {
            state = backend.status()
            isUpdating = false
        }
        do {
            if enabled { try backend.register() }
            else { try await backend.unregister() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
