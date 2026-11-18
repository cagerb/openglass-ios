// svc26 connection init: must send an empty type 3 message on every connection
// or the glasses refuse file shares.

import Foundation

final class ConnectionInitService: @unchecked Sendable {

    static let serviceConnectionInit = 26

    enum Phase: String {
        case idle = "Idle"
        case sent = "Init sent"
    }

    private enum MsgType {
        static let initMessage = 3
    }

    private(set) var phase: Phase = .idle

    var log: ((String) -> Void)?

    // MARK: - Send init

    func sendInit(link: AirShieldLink) {
        let channelID = link.openChannel()
        phase = .sent
        emit("Sending svc26 connection init (empty type 3)")

        link.sendMessage(
            channelID: channelID,
            serviceID: Self.serviceConnectionInit,
            messageType: MsgType.initMessage,
            payload: []
        )
    }

    // MARK: - Helpers

    func reset() {
        phase = .idle
    }

    private func emit(_ message: String) {
        log?("[ConnInit] \(message)")
    }
}
