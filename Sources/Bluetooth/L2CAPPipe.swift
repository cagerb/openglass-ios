import Foundation
import CoreBluetooth

/// The two streams of an open L2CAP channel, as a byte pipe.
///
/// CoreBluetooth hands an L2CAP channel over as an NSStream pair, which needs a run
/// loop. All stream work here happens on the main run loop; bytes and events leave
/// through the callbacks, which are called on the main thread.
final class L2CAPPipe: NSObject, StreamDelegate, @unchecked Sendable {

    /// Bytes read from the glasses, in order.
    var onBytes: (@Sendable ([UInt8]) -> Void)?
    /// Stream events worth a log line.
    var onEvent: (@Sendable (String) -> Void)?
    /// The channel ended: the peer closed it or a stream failed.
    var onClosed: (@Sendable (String) -> Void)?

    let psm: CBL2CAPPSM

    // The channel must stay referenced or CoreBluetooth closes it.
    private let channel: CBL2CAPChannel
    private let input: InputStream
    private let output: OutputStream
    // Main thread only.
    private var outBuffer: [UInt8] = []
    private var closed = false

    init?(channel: CBL2CAPChannel) {
        guard let input = channel.inputStream, let output = channel.outputStream else { return nil }
        self.channel = channel
        self.input = input
        self.output = output
        self.psm = channel.psm
        super.init()
    }

    /// Schedule and open both streams. Set the callbacks first.
    func open() {
        DispatchQueue.main.async { [self] in
            guard !closed else { return }
            input.delegate = self
            output.delegate = self
            input.schedule(in: .main, forMode: .default)
            output.schedule(in: .main, forMode: .default)
            input.open()
            output.open()
        }
    }

    /// Queue bytes for the glasses. Each call is written whole, in order.
    func write(_ bytes: [UInt8]) {
        DispatchQueue.main.async { [self] in
            guard !closed else { return }
            outBuffer += bytes
            flush()
        }
    }

    func close() {
        DispatchQueue.main.async { [self] in
            shutDown()
        }
    }

    // MARK: - Main thread

    private func shutDown() {
        guard !closed else { return }
        closed = true
        outBuffer.removeAll()
        input.delegate = nil
        output.delegate = nil
        input.close()
        output.close()
        input.remove(from: .main, forMode: .default)
        output.remove(from: .main, forMode: .default)
    }

    private func flush() {
        while !outBuffer.isEmpty && output.hasSpaceAvailable {
            let written = output.write(outBuffer, maxLength: outBuffer.count)
            guard written > 0 else { break }
            outBuffer.removeFirst(written)
        }
    }

    private func drainInput() {
        var collected: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let read = input.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            collected += buffer[0..<read]
        }
        if !collected.isEmpty {
            onBytes?(collected)
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard !closed else { return }
        let name = aStream === input ? "input" : "output"
        switch eventCode {
        case .openCompleted:
            onEvent?("L2CAP \(name) stream open")
        case .hasBytesAvailable:
            if aStream === input { drainInput() }
        case .hasSpaceAvailable:
            if aStream === output { flush() }
        case .errorOccurred:
            let reason = aStream.streamError?.localizedDescription ?? "unknown error"
            shutDown()
            onClosed?("L2CAP \(name) stream error: \(reason)")
        case .endEncountered:
            shutDown()
            onClosed?("L2CAP \(name) stream ended: the glasses closed the channel")
        default:
            break
        }
    }
}
