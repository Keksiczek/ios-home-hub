import Foundation
import UIKit

/// Reports local device state — battery, storage, OS version, device
/// name — as a compact, structured string the model can quote in a
/// final answer.
///
/// The skill never leaves the device (no network, no identifiers beyond
/// `UIDevice.name` which is user-assigned) and returns a Czech- and
/// English-friendly line-per-attribute format so the model can parrot
/// it verbatim without parsing JSON.
struct DeviceInfoSkill: Skill {
    let name = "DeviceInfo"
    let description = """
    Reports local device status: battery level and charging state, free \
    and total storage, iOS version, and device model/name. Input is \
    ignored — pass an empty string or the keyword "all".
    """

    func execute(input: String) async throws -> String {
        let snapshot = await MainActor.run { snapshotDevice() }
        return snapshot.render()
    }

    // MARK: - Snapshot

    /// Pulled as one call so every line comes from the same moment in
    /// time; otherwise the battery-level read and the charging-state
    /// read could disagree across a battery-status notification.
    @MainActor
    private func snapshotDevice() -> Snapshot {
        let device = UIDevice.current
        let previousMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = previousMonitoring }

        let batteryLevel: Int? = {
            let raw = device.batteryLevel          // -1 when unknown
            guard raw >= 0 else { return nil }
            return Int((raw * 100).rounded())
        }()

        let batteryState: String = {
            switch device.batteryState {
            case .charging: return "charging"
            case .full:     return "full"
            case .unplugged: return "on battery"
            case .unknown:   return "unknown"
            @unknown default: return "unknown"
            }
        }()

        let (freeBytes, totalBytes) = storageBytes()

        return Snapshot(
            deviceName: device.name,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            model: device.model,
            batteryLevel: batteryLevel,
            batteryState: batteryState,
            freeStorageBytes: freeBytes,
            totalStorageBytes: totalBytes
        )
    }

    /// Returns `(free, total)` in bytes. Falls back to `(nil, nil)` if the
    /// volume attribute read fails — better to omit the line than to print
    /// zero and mislead the user.
    private func storageBytes() -> (Int64?, Int64?) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return (nil, nil)
        }
        return (values.volumeAvailableCapacityForImportantUsage, values.volumeTotalCapacity.map(Int64.init))
    }

    // MARK: - Rendering

    private struct Snapshot {
        let deviceName: String
        let systemName: String
        let systemVersion: String
        let model: String
        let batteryLevel: Int?
        let batteryState: String
        let freeStorageBytes: Int64?
        let totalStorageBytes: Int64?

        func render() -> String {
            var lines: [String] = []
            lines.append("Device: \(deviceName) (\(model))")
            lines.append("OS: \(systemName) \(systemVersion)")

            if let level = batteryLevel {
                lines.append("Battery: \(level)% — \(batteryState)")
            } else {
                lines.append("Battery: unavailable (\(batteryState))")
            }

            if let free = freeStorageBytes, let total = totalStorageBytes, total > 0 {
                let fmt = ByteCountFormatter()
                fmt.allowedUnits = [.useGB, .useMB]
                fmt.countStyle = .file
                lines.append("Storage: \(fmt.string(fromByteCount: free)) free of \(fmt.string(fromByteCount: total))")
            }

            return lines.joined(separator: "\n")
        }
    }
}
