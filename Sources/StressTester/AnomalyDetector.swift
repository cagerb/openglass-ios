import Foundation

public actor AnomalyDetector {

    public enum Anomaly: Sendable {
        case bleDisconnect(afterPacket: Int, timestamp: Date)
        case l2capClosed(afterPacket: Int, timestamp: Date)
        case responseTimeout(afterPacket: Int, waitedSeconds: Double, timestamp: Date)
        case glassesMissing(afterPacket: Int, missingForSeconds: Double, timestamp: Date)
        case unexpectedData(afterPacket: Int, data: [UInt8], timestamp: Date)

        var packetIndex: Int {
            switch self {
            case .bleDisconnect(let idx, _),
                 .l2capClosed(let idx, _),
                 .responseTimeout(let idx, _, _),
                 .glassesMissing(let idx, _, _),
                 .unexpectedData(let idx, _, _):
                return idx
            }
        }

        var timestamp: Date {
            switch self {
            case .bleDisconnect(_, let ts),
                 .l2capClosed(_, let ts),
                 .responseTimeout(_, _, let ts),
                 .glassesMissing(_, _, let ts),
                 .unexpectedData(_, _, let ts):
                return ts
            }
        }

        var label: String {
            switch self {
            case .bleDisconnect: return "BLE Disconnect"
            case .l2capClosed: return "L2CAP Closed"
            case .responseTimeout: return "Timeout"
            case .glassesMissing: return "Glasses Missing"
            case .unexpectedData: return "Unexpected Data"
            }
        }

        var severity: Severity {
            switch self {
            case .bleDisconnect: return .high
            case .l2capClosed: return .high
            case .responseTimeout: return .medium
            case .glassesMissing: return .critical
            case .unexpectedData: return .low
            }
        }

        enum Severity: String, Sendable {
            case low, medium, high, critical
        }
    }

    private(set) var anomalies: [Anomaly] = []
    private var onAnomaly: (@Sendable (Anomaly) -> Void)?

    public func setCallback(_ callback: @escaping @Sendable (Anomaly) -> Void) {
        onAnomaly = callback
    }

    public func record(_ anomaly: Anomaly) {
        anomalies.append(anomaly)
        onAnomaly?(anomaly)
    }

    public func reset() {
        anomalies.removeAll()
    }

    public var count: Int { anomalies.count }

    /// Export all anomalies as a JSON-compatible array of dictionaries.
    public func exportJSON() -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        return anomalies.map { anomaly in
            var dict: [String: Any] = [
                "type": anomaly.label,
                "severity": anomaly.severity.rawValue,
                "packetIndex": anomaly.packetIndex,
                "timestamp": formatter.string(from: anomaly.timestamp),
            ]
            switch anomaly {
            case .responseTimeout(_, let waited, _):
                dict["waitedSeconds"] = waited
            case .glassesMissing(_, let missing, _):
                dict["missingForSeconds"] = missing
            case .unexpectedData(_, let data, _):
                dict["dataHex"] = data.map { String(format: "%02x", $0) }.joined()
            default:
                break
            }
            return dict
        }
    }
}
