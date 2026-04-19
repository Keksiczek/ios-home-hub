import Foundation
import HomeKit

/// Errors produced by `HomeKitSkill`. They surface either through the
/// `Skill.execute(input:)` `throws` channel (when `WidgetActionHandler`
/// uses the throwing path) or are rendered back to the LLM by
/// `SkillManager.execute(_:)` as `"Error executing …"` strings.
///
/// Each case carries the localised Czech message that the model and the
/// UI used to read directly so user-visible output stays unchanged when
/// the error is rendered through `localizedDescription`.
enum HomeKitSkillError: LocalizedError, Equatable {
    case noHomeFound
    case invalidJSON
    case accessoryNotFound(name: String)
    case characteristicUnavailable(characteristic: String, accessory: String)
    case writeFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .noHomeFound:
            return "Chyba: Žádná HomeKit domácnost nebyla na tomto zařízení nalezena. Ujisti se, že máš iOS Domácnost nastavenou a oprávnění povolená."
        case .invalidJSON:
            return "Chyba: Neplatný JSON formát. Odpověz POUZE JSONem, například: {\"accessoryName\": \"Světlo obývák\", \"characteristic\": \"powerState\", \"value\": true}"
        case .accessoryNotFound(let name):
            return "Chyba: Příslušenství '\(name)' se v domácnosti nenachází."
        case .characteristicUnavailable(let characteristic, let accessory):
            return "Chyba: Požadovaná vlastnost (\(characteristic)) není u zařízení '\(accessory)' dostupná."
        case .writeFailed(let reason):
            return "Chyba při aktualizaci: \(reason)"
        }
    }
}

struct HomeKitSkill: Skill {
    let name = "HomeKitSearch"
    let description = "Čte stavy chytrých zařízení z HomeKitu a umožňuje jejich ovládání. Vstupy: 'status' (vypíše všechny stavy všech senzorů a světel) nebo JSON s povely pro úpravu: {\"accessoryName\": \"Světlo\", \"characteristic\": \"powerState\", \"value\": true}."

    /// Stable English prefix prepended to every successful update. Lets
    /// callers (e.g. `WidgetActionHandler`) detect success without parsing
    /// localised Czech keywords. The Czech "Úspěch:" remains as the
    /// human-readable suffix for the LLM and chat UI.
    static let successPrefix = "OK"

    func execute(input: String) async throws -> String {
        let manager = await HomeKitManager.shared.ensureReady()

        guard let primaryHome = manager.primaryHome ?? manager.homes.first else {
            throw HomeKitSkillError.noHomeFound
        }

        let cleanInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanInput.lowercased() == "status" || cleanInput.isEmpty {
            return generateStatusReport(for: primaryHome)
        } else {
            return try await applyChanges(from: cleanInput, in: primaryHome)
        }
    }
    
    private func generateStatusReport(for home: HMHome) -> String {
        var lines = ["Stav domácnosti '\(home.name)':"]
        for accessory in home.accessories {
            for service in accessory.services {
                if service.serviceType == HMServiceTypeLightbulb || service.serviceType == HMServiceTypeTemperatureSensor || service.serviceType == HMServiceTypeOutlet {
                    for char in service.characteristics {
                        switch char.characteristicType {
                        case HMCharacteristicTypePowerState:
                            let value = (char.value as? Bool) ?? false
                            lines.append("- \(accessory.name): \(value ? "ZAPNUTO" : "VYPNUTO")")
                        case HMCharacteristicTypeCurrentTemperature:
                            let value = (char.value as? Double) ?? 0.0
                            lines.append("- \(accessory.name) (Teplota): \(String(format: "%.1f", value)) °C")
                        default:
                            break
                        }
                    }
                }
            }
        }
        
        if lines.count == 1 {
            return "Domácnost '\(home.name)' je prázdná nebo neobsahuje podporovaná zařízení (Světla, Teploměry, Zásuvky)."
        }
        return lines.joined(separator: "\n")
    }
    
    private func applyChanges(from jsonString: String, in home: HMHome) async throws -> String {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targetName = dict["accessoryName"] as? String,
              let targetChar = dict["characteristic"] as? String,
              let targetValue = dict["value"] else {
            throw HomeKitSkillError.invalidJSON
        }

        guard let accessory = home.accessories.first(where: { $0.name.lowercased() == targetName.lowercased() }) else {
            throw HomeKitSkillError.accessoryNotFound(name: targetName)
        }

        var targetType = HMCharacteristicTypePowerState
        if targetChar.lowercased() == "brightness" {
            targetType = HMCharacteristicTypeBrightness
        }

        for service in accessory.services {
            if let char = service.characteristics.first(where: { $0.characteristicType == targetType }) {
                do {
                    try await char.writeValue(targetValue)
                    return "\(Self.successPrefix): '\(targetName)' bylo úspěšně aktualizováno."
                } catch {
                    throw HomeKitSkillError.writeFailed(reason: error.localizedDescription)
                }
            }
        }

        throw HomeKitSkillError.characteristicUnavailable(characteristic: targetChar, accessory: targetName)
    }
}

actor HomeKitManagerDelegateProxy: NSObject, HMHomeManagerDelegate {
    private var continuations: [CheckedContinuation<HMHomeManager, Never>] = []
    private var isReady = false
    private var cachedManager: HMHomeManager?

    func ensureReady(manager: HMHomeManager) async -> HMHomeManager {
        if isReady, let m = cachedManager { return m }
        return await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }
    
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task {
            await self.didUpdateHomes(manager)
        }
    }

    private func didUpdateHomes(_ manager: HMHomeManager) {
        self.cachedManager = manager
        self.isReady = true
        let pending = continuations
        continuations.removeAll()
        for c in pending {
            c.resume(returning: manager)
        }
    }
}

/// Helper singleton bridging HMHomeManager's async initialization to Concurrency
class HomeKitManager {
    static let shared = HomeKitManager()
    
    private var manager: HMHomeManager!
    private let proxy = HomeKitManagerDelegateProxy()
    
    private init() {
        DispatchQueue.main.async {
            self.manager = HMHomeManager()
            self.manager.delegate = self.proxy
        }
    }
    
    func ensureReady() async -> HMHomeManager {
        return await proxy.ensureReady(manager: self.manager)
    }
}
