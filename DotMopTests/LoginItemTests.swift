import CoreServices
import Foundation
import XCTest
@testable import DotMop

final class LoginItemTests: XCTestCase {
    func testLoginLaunchUsesSystemAppleEventAndNeverOpensAWindow() throws {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                           eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertEqual(LaunchContext(event: event), .manual)
        XCTAssertFalse(try XCTUnwrap(LaunchContext(event: event)).shouldScan(scanOnOpen: false))
        event.setParam(NSAppleEventDescriptor(typeCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        let login = try XCTUnwrap(LaunchContext(event: event))
        XCTAssertEqual(login, .login)
        XCTAssertFalse(login.opensMainWindow)
        XCTAssertTrue(login.shouldScan(scanOnOpen: false))
        XCTAssertNil(LaunchContext(event: nil))
    }

    @MainActor
    func testRegistrationErrorReflectsActualSystemStatusAndPreservesReason() async {
        let backend = LoginItemService.Backend(status: { .notFound }, register: { throw POSIXError(.EPERM) }, unregister: {})
        let service = LoginItemService(backend: backend)
        await service.setEnabled(true)
        XCTAssertEqual(service.state, .notFound)
        XCTAssertEqual(service.errorMessage, POSIXError(.EPERM).localizedDescription)
        XCTAssertFalse(service.isUpdating)
    }

    @MainActor
    func testPendingApprovalIsDistinctAndCanBeCancelled() async {
        var systemState = LoginItemService.State.notRegistered
        let backend = LoginItemService.Backend(
            status: { systemState },
            register: { systemState = .requiresApproval },
            unregister: { systemState = .notRegistered }
        )
        let service = LoginItemService(backend: backend)
        await service.setEnabled(true)
        XCTAssertEqual(service.state, .requiresApproval)
        XCTAssertFalse(service.isEnabled)
        await service.setEnabled(false)
        XCTAssertEqual(service.state, .notRegistered)
        XCTAssertNil(service.errorMessage)
    }
}
