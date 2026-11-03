import AppKit
import ApplicationServices

/// Activar ventanas al pasar el mouse (experimental).
///
/// Cuando el mouse entra a una ventana de otra app y se queda un instante, esa app se activa
/// SIN traer la ventana al frente: la ventana queda donde está, pero reacciona al mouse como si
/// estuviera activa (los controles de un video, los hover de la página…).
///
/// Para no repetir los problemas de las apps de "focus follows mouse":
/// - nunca le saca el foco a una ventana o app que acaba de aparecer (una ventana nueva, el
///   diálogo de Touch ID): espera a que pase un momento desde la última activación ajena;
/// - nunca le saca el foco a un diálogo ni a los agentes de contraseña y Touch ID del sistema;
/// - solo actúa cuando el mouse se MUEVE hacia una ventana: si está quieto sobre otra ventana
///   mientras escribís, no pasa nada;
/// - pasar de largo por encima de una ventana no la activa.
///
/// Gasto: un event tap de solo escucha, sin nada corriendo con el mouse quieto. La lista de
/// ventanas se renueva como mucho 4 veces por segundo, y solo mientras el mouse se mueve.
final class HoverFocus {
    private struct Win {
        let frame: CGRect
        let pid: pid_t
        let id: CGWindowID
        let layer: Int
    }

    /// Cuánto tiene que quedarse el mouse sobre la ventana antes de activarla.
    private let dwell: TimeInterval = 0.15
    /// Después de que algo ajeno cambie el foco (una app o ventana nueva), cuánto se espera.
    private let holdAfterExternalFocus: CFTimeInterval = 1.5
    private let listLifetime: CFTimeInterval = 0.25
    /// Apps del sistema que piden contraseña o Touch ID: nunca se les saca el foco.
    private let protectedApps: Set<String> = [
        "com.apple.SecurityAgent",
        "com.apple.LocalAuthentication.UIAgent",
        "com.apple.coreservices.uiagent",
        "com.apple.UserNotificationCenter",
    ]

    private let settings: Settings
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var observer: NSObjectProtocol?

    private var windows: [Win] = []
    private var windowsTime: CFAbsoluteTime = 0
    private var frontPID: pid_t = 0
    private var frontFocusedWindow: CGWindowID?
    private var lastExternalFocus: CFAbsoluteTime = 0
    private var lastOwnActivation: (pid: pid_t, time: CFAbsoluteTime)?
    private var candidatePID: pid_t?
    private var pendingWork: DispatchWorkItem?

    init(settings: Settings) {
        self.settings = settings
    }

    var isRunning: Bool { tap != nil }

    // MARK: - Ciclo de vida

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.mouseMoved.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<HoverFocus>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .tailAppendEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source

        frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
            self.frontPID = pid
            self.frontFocusedWindow = nil
            self.windowsTime = 0
            if !self.isOwnActivation(pid) { self.lastExternalFocus = CFAbsoluteTimeGetCurrent() }
        }
    }

    func stop() {
        pendingWork?.cancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        tap = nil
        source = nil
        observer = nil
        pendingWork = nil
        candidatePID = nil
        windows = []
    }

    // MARK: - Movimiento

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .mouseMoved, settings.enabled else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - windowsTime > listLifetime { refresh(now: now) }

        let target = window(at: event.location)
        let pid = target?.pid

        // Solo se programa algo cuando el mouse entra a otra app: moverse dentro de la misma no
        // reinicia la espera, y salir antes de tiempo la cancela (pasar de largo no activa).
        guard pid != candidatePID else { return }
        candidatePID = pid
        pendingWork?.cancel()
        pendingWork = nil
        guard let target, target.pid != frontPID else { return }

        let work = DispatchWorkItem { [weak self] in self?.activateIfStillThere(target) }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }

    private func activateIfStillThere(_ target: Win) {
        pendingWork = nil
        guard settings.enabled, target.pid != frontPID else { return }
        guard let here = CGEvent(source: nil)?.location,
              let current = window(at: here), current.pid == target.pid else { return }
        guard canTakeFocus(),
              let app = NSRunningApplication(processIdentifier: target.pid),
              app.activationPolicy == .regular,
              !settings.isExcluded(app.bundleIdentifier) else { return }
        // Solo ventanas normales: paneles flotantes, paletas y similares no se tocan.
        if let ax = WindowLocator.axWindow(pid: target.pid, windowID: current.id),
           !WindowLocator.isStandardWindow(ax) { return }

        lastOwnActivation = (target.pid, CFAbsoluteTimeGetCurrent())
        WindowActivator.activateWithoutRaising(pid: target.pid, windowID: current.id)
    }

    /// ¿Se le puede sacar el foco a lo que está activo ahora?
    private func canTakeFocus() -> Bool {
        // Algo ajeno acaba de cambiar el foco (una app o una ventana nueva): se respeta.
        if CFAbsoluteTimeGetCurrent() - lastExternalFocus < holdAfterExternalFocus { return false }
        guard let front = NSWorkspace.shared.frontmostApplication else { return true }
        if let id = front.bundleIdentifier, protectedApps.contains(id) { return false }
        // Un diálogo abierto en la app activa (guardar, permisos, Touch ID dentro de la app…).
        var value: CFTypeRef?
        let appElement = WindowLocator.appElement(front.processIdentifier)
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let window = value as! AXUIElement
            var subrole: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success,
               let subrole = subrole as? String,
               subrole == kAXDialogSubrole as String || subrole == kAXSystemDialogSubrole as String {
                return false
            }
            var sheets: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &sheets) == .success,
               let children = sheets as? [AXUIElement],
               children.contains(where: { role(of: $0) == "AXSheet" }) {
                return false
            }
        }
        return true
    }

    private func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func isOwnActivation(_ pid: pid_t) -> Bool {
        guard let own = lastOwnActivation else { return false }
        return own.pid == pid && CFAbsoluteTimeGetCurrent() - own.time < 1
    }

    // MARK: - Ventanas

    private func window(at point: CGPoint) -> Win? {
        // Ordenadas de adelante hacia atrás: la primera que contiene el punto es la visible.
        // Si es un menú, el Dock u otra capa del sistema, no se activa nada.
        guard let top = windows.first(where: { $0.frame.contains(point) }), top.layer == 0 else { return nil }
        return top
    }

    private func refresh(now: CFAbsoluteTime) {
        windowsTime = now
        let myPID = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        windows = list.compactMap { info in
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  pid != myPID else { return nil }
            if ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) < 0.01 { return nil }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            return Win(frame: frame, pid: pid, id: id, layer: layer)
        }

        // Una ventana nueva en la app activa (por ejemplo, un diálogo de Touch ID dentro de ella)
        // cuenta como un cambio de foco ajeno: se la deja tranquila un momento.
        let focused = WindowLocator.focusedWindowID(of: frontPID)
        if let focused, let previous = frontFocusedWindow, focused != previous, !isOwnActivation(frontPID) {
            lastExternalFocus = now
        }
        frontFocusedWindow = focused
    }
}
