import AppKit
import ApplicationServices

struct TargetWindow {
    let pid: pid_t
    let windowID: CGWindowID
    let layer: Int
}

enum WindowLocator {
    /// Ventana que está más arriba en el punto dado (coordenadas globales, origen arriba a la izquierda,
    /// las mismas que usa CGEvent.location).
    static func window(at point: CGPoint) -> TargetWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let myPID = ProcessInfo.processInfo.processIdentifier

        // La lista viene ordenada de adelante hacia atrás.
        for info in list {
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(point) else { continue }

            // Ventanas invisibles (overlays transparentes) no cuentan.
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha < 0.01 { continue }

            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0

            if pid == myPID { return nil }
            return TargetWindow(pid: pid, windowID: wid, layer: layer)
        }
        return nil
    }

    static func appElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        // Si la app está colgada no queremos trabar el mouse de todo el sistema.
        AXUIElementSetMessagingTimeout(app, 0.05)
        return app
    }

    /// CGWindowID de la ventana que tiene el foco dentro de la app.
    static func focusedWindowID(of pid: pid_t) -> CGWindowID? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(value as! AXUIElement, &wid) == .success else { return nil }
        return wid
    }

    static func isFrontmost(_ pid: pid_t) -> Bool {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement(pid), kAXFrontmostAttribute as CFString, &value) == .success,
           let flag = value as? Bool {
            return flag
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// El AXUIElement de una ventana puntual, buscado por su CGWindowID.
    static func axWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement(pid), kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for window in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(window, &wid) == .success, wid == windowID {
                return window
            }
        }
        return nil
    }

    /// true si la ventana es una ventana "normal" (no un panel flotante, paleta, tooltip, etc.).
    static func isStandardWindow(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String else { return true }
        return subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String
    }
}
