// svc36 change-owner: register a new P-256 owner key with the glasses through Meta's
// signed ownership receipts. This replaces the previous owner and gives OpenGlass full
// control of the device.
//
// Flow (all on svc36, one channel):
//   1. IDENTITY_REQUEST  (0x3000) → IDENTITY_RESPONSE (0x3001): get cert + serial + nonce
//   2. SKIP_CHALLENGE    (0x2000) → SKIP_CHALLENGE_ACK (0x2001): get the device nonce
//   3. START_CHANGE_OWNER_REQ (0x2002) → START_CHANGE_OWNER_RESP (0x2003): send Meta's
//      pending receipt, receive the glasses' device-pending receipt. The user may need to
//      press the button on the glasses before they respond.
//   4. FINISH_CHANGE_OWNER_REQ (0x2004) → FINISH_CHANGE_OWNER_RESP (0x2005): send Meta's
//      final receipt, receive acknowledgement.
//
// After step 4, the glasses know our key. The trust exchange (OwnerTrustExchange) should
// run immediately afterward to prove we hold it.

import Foundation
import CryptoKit

final class ChangeOwnerExchange {

    enum Phase: String {
        case idle               = "Idle"
        case requestingIdentity = "Requesting identity..."
        case skippingChallenge  = "Getting device nonce..."
        case callingMeta        = "Contacting Meta..."
        case startingChange     = "Starting change-owner..."
        case waitingForPress    = "Press the button on your glasses"
        case finalizingWithMeta = "Finalizing with Meta..."
        case finishingChange    = "Finishing change-owner..."
        case succeeded          = "Ownership claimed"
        case failed             = "Failed"
    }

    private enum MsgType {
        static let identityRequest       = 0x3000
        static let identityResponse      = 0x3001
        static let skipChallenge         = 0x2000
        static let skipChallengeAck      = 0x2001
        static let startChangeOwnerReq   = 0x2002
        static let startChangeOwnerResp  = 0x2003
        static let finishChangeOwnerReq  = 0x2004
        static let finishChangeOwnerResp = 0x2005
    }

    private static let statusInvalidUserID = 0x1042

    private(set) var phase: Phase = .idle
    private(set) var failureReason: String = ""
    private(set) var deviceIdentity: MetaAuth.DeviceIdentity?

    var log: ((String) -> Void)?

    private var channelID = 0
    private var firstMessage = true
    private var pendingContinuation: CheckedContinuation<AirShieldMessage, Error>?
    private var deferredMessages: [AirShieldMessage] = []

    // MARK: - Run the full flow

    func start(
        link: AirShieldLink,
        ownerPubkey64: [UInt8],
        tokens: MetaAuth.Tokens,
        metaAuth: MetaAuth
    ) {
        phase = .requestingIdentity
        channelID = link.openChannel()
        firstMessage = true

        Task {
            do {
                emit("=== CHANGE-OWNER STARTING ===")

                // Step 1: Identity request
                emit("Sending IDENTITY_REQUEST (0x3000)")
                send(link, type: MsgType.identityRequest)
                let identResp = try await waitForMessage(type: MsgType.identityResponse, timeout: 20)
                let identFields = ProtoWire.parse(identResp.payload)
                let identity = MetaAuth.DeviceIdentity(
                    certDER: Data(identFields.bytes(1)),
                    serial: String(decoding: identFields.bytes(2), as: UTF8.self),
                    secondaryCert: Data(identFields.bytes(5))
                )
                deviceIdentity = identity
                emit("Got identity: serial=\(identity.serial)")

                // Step 2: Skip challenge → get device nonce
                phase = .skippingChallenge
                emit("Sending SKIP_CHALLENGE (0x2000)")
                send(link, type: MsgType.skipChallenge)
                let ackResp = try await waitForMessage(type: MsgType.skipChallengeAck, timeout: 20)
                let nonce = ProtoWire.parse(ackResp.payload).bytes(1)
                emit("Got device nonce: \(nonce.count) bytes")

                // Step 3: pair_request → start change owner
                phase = .callingMeta
                emit("Calling Meta pair_request...")
                let pendingReceipt = try await metaAuth.pairRequest(
                    tokens: tokens,
                    certDER: identity.certDER,
                    serial: identity.serial,
                    deviceNonce: Data(nonce),
                    appPubkey: Data(ownerPubkey64),
                    secondaryCert: identity.secondaryCert
                )
                emit("Got pending receipt from Meta (\(pendingReceipt.bodyJSON.count) bytes)")

                phase = .startingChange
                emit("Sending START_CHANGE_OWNER_REQ (0x2002)")
                send(link, type: MsgType.startChangeOwnerReq, payload: Array(pendingReceipt.encode()))

                // The glasses may require a physical button press before responding.
                // Give it 90 seconds for the user to press.
                let devicePendingResp: AirShieldMessage
                do {
                    devicePendingResp = try await waitForMessage(type: MsgType.startChangeOwnerResp, timeout: 90, onSlow: { [weak self] in
                        self?.phase = .waitingForPress
                        self?.emit("Waiting for button press on the glasses...")
                    })
                } catch {
                    throw ChangeOwnerError.timeout("Timed out waiting for START_CHANGE_OWNER_RESP. Did you press the button on the glasses?")
                }
                let devicePendingReceipt = MetaAuth.Receipt.decode(Array(devicePendingResp.payload))
                emit("Got device pending receipt (\(devicePendingReceipt.bodyJSON.count) bytes)")

                // Step 4: pair → finish change owner
                phase = .finalizingWithMeta
                emit("Calling Meta pair (final receipt)...")
                let finalReceipt = try await metaAuth.pair(
                    tokens: tokens,
                    devicePendingReceipt: devicePendingReceipt
                )
                emit("Got final receipt from Meta (\(finalReceipt.bodyJSON.count) bytes)")

                phase = .finishingChange
                emit("Sending FINISH_CHANGE_OWNER_REQ (0x2004)")
                send(link, type: MsgType.finishChangeOwnerReq, payload: Array(finalReceipt.encode()))
                _ = try await waitForMessage(type: MsgType.finishChangeOwnerResp, timeout: 20)

                phase = .succeeded
                emit("=== CHANGE-OWNER SUCCEEDED ===")
                emit("OpenGlass is now the owner of \(identity.serial)")

            } catch let error as ChangeOwnerError {
                fail(error.localizedDescription ?? "unknown error")
            } catch let error as MetaAuthError {
                if case .wrongOwner = error {
                    fail("These glasses belong to another Meta account")
                } else {
                    fail(error.localizedDescription ?? "Meta API error")
                }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: - Message handler (called from bleQueue by BluetoothManager)

    func handleMessage(_ message: AirShieldMessage, link: AirShieldLink) {
        let header = message.header

        if header.hasError {
            let code = header.errorID
            if code == Self.statusInvalidUserID {
                fail("These glasses belong to another Meta account (0x1042)")
            } else {
                fail("Glasses returned error 0x\(String(format: "%04x", code))")
            }
            pendingContinuation?.resume(throwing: ChangeOwnerError.rejected(code))
            pendingContinuation = nil
            return
        }

        if let continuation = pendingContinuation {
            pendingContinuation = nil
            continuation.resume(returning: message)
        } else {
            deferredMessages.append(message)
        }
    }

    // MARK: - Internals

    private func send(_ link: AirShieldLink, type: Int, payload: [UInt8] = []) {
        let svcID = firstMessage ? AirShieldLink.serviceIdentity : nil
        firstMessage = false
        link.sendMessage(channelID: channelID, serviceID: svcID, messageType: type, payload: payload)
    }

    private func waitForMessage(type: Int, timeout: TimeInterval, onSlow: (() -> Void)? = nil) async throws -> AirShieldMessage {
        if let idx = deferredMessages.firstIndex(where: { $0.header.messageType == type }) {
            return deferredMessages.remove(at: idx)
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AirShieldMessage, Error>) in
            self.pendingContinuation = continuation

            Task {
                if let onSlow {
                    try? await Task.sleep(for: .seconds(3))
                    if self.pendingContinuation != nil {
                        onSlow()
                    }
                }
            }

            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if let pending = self.pendingContinuation {
                    self.pendingContinuation = nil
                    pending.resume(throwing: ChangeOwnerError.timeout("Timed out waiting for message 0x\(String(format: "%04x", type))"))
                }
            }
        }
    }

    private func fail(_ reason: String) {
        failureReason = reason
        phase = .failed
        emit("FAILED: \(reason)")
    }

    private func emit(_ message: String) {
        log?("[ChangeOwner] \(message)")
    }
}

enum ChangeOwnerError: LocalizedError {
    case timeout(String)
    case rejected(Int)
    case noLink

    var errorDescription: String? {
        switch self {
        case .timeout(let msg): return msg
        case .rejected(let code): return "Glasses rejected: 0x\(String(format: "%04x", code))"
        case .noLink: return "AirShield link is not secure"
        }
    }
}
