import CoreServices
import Foundation

enum LaunchContext: Equatable {
    case manual, login

    init?(event: NSAppleEventDescriptor?) {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return nil }
        // LaunchServices supplies the context in the open-application Apple event.
        let source = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.typeCodeValue
        self = source == OSType(keyAELaunchedAsLogInItem) || source == OSType(keyAELaunchedAsServiceItem) ? .login : .manual
    }

    var opensMainWindow: Bool { self == .manual }

    func shouldScan(scanOnOpen: Bool) -> Bool {
        self == .login || scanOnOpen
    }
}
