// svc15 assistant channel: replaces Meta AI with Claude.
//
// The glasses' built-in assistant flow:
//   1. User says "Hey Meta" or taps the touchpad → glasses start recording
//   2. Glasses stream opus-encoded audio chunks to the phone (svc15)
//   3. Phone processes the audio and sends a text/audio response back
//   4. Glasses play the response through their speakers
//
// Message types:
//   1  Glasses → Phone   Session start (user triggered assistant)
//   2  Glasses → Phone   Audio data chunk (opus from microphone)
//   3  Glasses → Phone   Recording complete (user stopped speaking)
//   4  Phone → Glasses   Response text (UTF-8, spoken by on-device TTS)
//   5  Phone → Glasses   Response audio chunk (raw audio for playback)
//   6  Phone → Glasses   Response complete
//   7  Phone → Glasses   Session end

import Foundation

final class AssistantService: @unchecked Sendable {

    static let serviceAssistant = 15
    static let serviceAssistantTrigger = 1023

    enum Phase: String {
        case idle        = "Ready"
        case listening   = "Listening..."
        case processing  = "Thinking..."
        case responding  = "Speaking..."
        case failed      = "Failed"
    }

    private enum MsgType {
        static let sessionStart      = 1
        static let audioChunk        = 2
        static let recordingComplete = 3
        static let responseText      = 4
        static let responseAudio     = 5
        static let responseComplete  = 6
        static let sessionEnd        = 7
    }

    struct AssistantRequest: Sendable {
        let audioChunks: [[UInt8]]
        let timestamp: Date
    }

    // MARK: - Observable state

    private(set) var phase: Phase = .idle
    private(set) var failureReason: String = ""

    var isListening: Bool { phase == .listening }
    private(set) var currentAudio: [[UInt8]] = []

    var log: ((String) -> Void)?
    var onRequest: (@Sendable (AssistantRequest) -> Void)?

    private(set) var channelID = 0
    private(set) var incomingChannelID = 0
    private var firstMessage = true
    private var sessionActive = false
    private var recordingStartTime: Date?
    /// Bumped on every accepted svc1023 trigger; lets the no-audio timeout ignore stale triggers.
    private(set) var triggerGeneration = 0
    /// Diagnostics: svc15 messages seen on this connection.
    private(set) var svc15MessagesSeen = 0

    // MARK: - Message handler (called from bleQueue by BluetoothManager)

    func handleMessage(_ message: AirShieldMessage, link: AirShieldLink) {
        let header = message.header

        svc15MessagesSeen += 1
        if header.messageType != MsgType.audioChunk || svc15MessagesSeen <= 5 {
            emit("svc15 message #\(svc15MessagesSeen): ch=\(String(format: "0x%04x", header.channelID)) type=\(header.messageType) err=\(header.hasError) len=\(message.payload.count) hex=\(Self.hex(message.payload.prefix(48)))")
        }

        if header.hasError {
            let code = header.errorID
            fail("Glasses returned error 0x\(String(format: "%04x", code))")
            return
        }

        switch header.messageType {
        case MsgType.sessionStart:
            handleSessionStart(message, link: link)

        case MsgType.audioChunk:
            handleAudioChunk(message)

        case MsgType.recordingComplete:
            handleRecordingComplete()

        default:
            emit("Unexpected svc15 type \(header.messageType)")
        }
    }

    // MARK: - Trigger from svc1023 (tap-and-hold or "Hey Meta")

    /// Returns true when the message was taken as an assistant trigger and a session started.
    @discardableResult
    func handleTrigger(_ message: AirShieldMessage, link: AirShieldLink) -> Bool {
        let header = message.header
        let ch = String(format: "0x%04x", header.channelID)
        emit("svc1023 step 1/4: message on ch=\(ch) type=\(header.messageType) err=\(header.hasError) closed=\(header.isClosed) len=\(message.payload.count)")
        emit("svc1023 payload hex: \(Self.hex(message.payload.prefix(96)))")
        emit("svc1023 payload text: \"\(Self.printable(message.payload.prefix(96)))\"")

        guard !header.hasError else {
            emit("svc1023 stopped at step 1: status 0x\(String(format: "%04x", header.errorID)), not a trigger")
            return false
        }
        guard header.messageType == 1 else {
            emit("svc1023 stopped at step 2: type \(header.messageType) is not the trigger type (1)")
            return false
        }
        emit("svc1023 step 2/4: type is 1")

        let intent = String(bytes: message.payload, encoding: .utf8) ?? Self.printable(message.payload[...])
        guard intent.lowercased().contains("assistant") else {
            emit("svc1023 stopped at step 3: payload does not mention \"assistant\"")
            return false
        }
        emit("svc1023 step 3/4: intent \"\(intent)\" accepted")

        if sessionActive {
            emit("svc1023: a session was already active — restarting it")
            reset()
        }
        sessionActive = true
        currentAudio = []
        recordingStartTime = Date()
        phase = .listening
        triggerGeneration += 1
        if channelID == 0 {
            channelID = link.openChannel()
            firstMessage = true
        }
        emit("svc1023 step 4/4: TRIGGER RECEIVED — now listening for svc15 audio (our channel \(String(format: "0x%04x", channelID)), nothing sent to the glasses)")
        emit("NOTE: svc15 bring-up (registration 1000/1001, streams 5000-5003, NetEvent 9000/9001) is not implemented yet, so the glasses are not expected to send audio")
        return true
    }

    /// Called a few seconds after a trigger. If nothing arrived on svc15, say so and go back to Ready.
    func checkTriggerTimeout(generation: Int) {
        guard generation == triggerGeneration, sessionActive, phase == .listening else { return }
        guard currentAudio.isEmpty else { return }
        emit("No svc15 audio arrived after the svc1023 trigger (\(svc15MessagesSeen) svc15 messages seen this connection) — back to Ready")
        reset()
    }

    // MARK: - Incoming: session start

    private func handleSessionStart(_ message: AirShieldMessage, link: AirShieldLink) {
        emit("=== ASSISTANT SESSION START ===")
        sessionActive = true
        currentAudio = []
        recordingStartTime = Date()
        phase = .listening
        incomingChannelID = message.header.channelID

        if channelID == 0 {
            channelID = link.openChannel()
            firstMessage = true
        }
    }

    // MARK: - Incoming: audio chunks

    private func handleAudioChunk(_ message: AirShieldMessage) {
        guard sessionActive else {
            emit("Audio chunk received outside session, ignoring")
            return
        }
        currentAudio.append(message.payload)
    }

    // MARK: - Incoming: recording complete

    private func handleRecordingComplete() {
        guard sessionActive else { return }
        emit("Recording complete: \(currentAudio.count) chunks, \(currentAudio.reduce(0) { $0 + $1.count }) bytes total")
        phase = .processing

        let request = AssistantRequest(
            audioChunks: currentAudio,
            timestamp: recordingStartTime ?? Date()
        )
        onRequest?(request)
    }

    // MARK: - Outgoing: send text response (type 4)

    func sendTextResponse(text: String, link: AirShieldLink) {
        guard sessionActive else {
            emit("Cannot send response: no active session")
            return
        }
        phase = .responding
        emit("Sending text response (\(text.count) chars)")

        let payload = Array(text.utf8)
        send(link, type: MsgType.responseText, payload: payload)
    }

    // MARK: - Outgoing: send audio response chunk (type 5)

    func sendAudioResponse(data: [UInt8], link: AirShieldLink) {
        guard sessionActive else { return }
        if phase != .responding { phase = .responding }
        send(link, type: MsgType.responseAudio, payload: data)
    }

    // MARK: - Outgoing: response complete (type 6)

    func sendResponseComplete(link: AirShieldLink) {
        guard sessionActive else { return }
        emit("Response complete")
        send(link, type: MsgType.responseComplete)
    }

    // MARK: - Outgoing: end session (type 7)

    func endSession(link: AirShieldLink) {
        emit("Ending assistant session")
        send(link, type: MsgType.sessionEnd)
        reset()
    }

    // MARK: - Full response cycle

    func sendFullTextResponse(text: String, link: AirShieldLink) {
        sendTextResponse(text: text, link: link)
        sendResponseComplete(link: link)
        endSession(link: link)
    }

    // MARK: - Helpers

    private func send(_ link: AirShieldLink, type: Int, payload: [UInt8] = []) {
        let svcID: Int? = firstMessage ? Self.serviceAssistant : nil
        link.sendMessage(
            channelID: channelID,
            serviceID: svcID,
            messageType: type,
            payload: payload
        )
        firstMessage = false
    }

    func reset() {
        phase = .idle
        failureReason = ""
        currentAudio = []
        sessionActive = false
        recordingStartTime = nil
        channelID = 0
        incomingChannelID = 0
        firstMessage = true
    }

    private func fail(_ reason: String) {
        phase = .failed
        failureReason = reason
        emit("FAILED: \(reason)")
        sessionActive = false
    }

    private static func hex(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func printable(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." })
    }

    private func emit(_ message: String) {
        log?("[Assistant] \(message)")
    }
}
