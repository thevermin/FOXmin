import Foundation
import CoreGraphics

final class Settings {
    private let defaults = UserDefaults.standard

    private func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    var enabled: Bool {
        get { bool("enabled", default: true) }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    var rightClick: Bool {
        get { bool("rightClick", default: true) }
        set { defaults.set(newValue, forKey: "rightClick") }
    }

    var middleClick: Bool {
        get { bool("middleClick", default: false) }
        set { defaults.set(newValue, forKey: "middleClick") }
    }

    /// Cuánto se espera a que la ventana se active antes de reenviar el click.
    enum Speed: String, CaseIterable {
        case fast, normal, patient

        var title: String {
            switch self {
            case .fast: return L("Fast")
            case .normal: return L("Normal")
            case .patient: return L("Patient (slow apps)")
            }
        }

        /// Tiempo máximo esperando que la ventana se confirme como activa.
        var activationTimeout: CFTimeInterval {
            switch self {
            case .fast: return 0.25
            case .normal: return 0.35
            case .patient: return 0.8
            }
        }

        /// Pausa después de activar, para que la app termine de procesar el cambio de foco.
        var settleDelay: TimeInterval {
            switch self {
            case .fast: return 0.005
            case .normal: return 0.015
            case .patient: return 0.06
            }
        }
    }

    var speed: Speed {
        get { defaults.string(forKey: "speed").flatMap(Speed.init(rawValue:)) ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: "speed") }
    }

    /// Bundle IDs de apps donde FOXmin no interviene.
    var excludedApps: [String] {
        get { defaults.stringArray(forKey: "excludedApps") ?? [] }
        set { defaults.set(newValue, forKey: "excludedApps") }
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedApps.contains(bundleID)
    }

    func exclude(_ bundleID: String) {
        if !excludedApps.contains(bundleID) { excludedApps.append(bundleID) }
    }

    func toggleExcluded(_ bundleID: String) {
        var list = excludedApps
        if let index = list.firstIndex(of: bundleID) {
            list.remove(at: index)
        } else {
            list.append(bundleID)
        }
        excludedApps = list
    }

    func handles(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown: return true
        case .rightMouseDown: return rightClick
        case .otherMouseDown: return middleClick
        default: return false
        }
    }
}
