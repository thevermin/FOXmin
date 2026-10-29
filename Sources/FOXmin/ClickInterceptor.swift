import AppKit
import ApplicationServices

/// Corazón de FOXmin.
///
/// Intercepta cada click antes de que llegue a cualquier app. Si el click cae sobre una
/// ventana que no está activa, lo retiene, activa esa ventana y recién ahí lo reenvía,
/// para que el mismo click que activa la ventana también haga su acción (como en Windows).
final class ClickInterceptor {
    /// Marca que llevan los eventos que reenviamos nosotros, para no volver a interceptarlos.
    static let marker: Int64 = 0x464F_584D // "FOXM"

    private struct Pending {
        let pid: pid_t
        let windowID: CGWindowID
        let started: CFAbsoluteTime
        var events: [CGEvent]
    }

    private let settings: Settings
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pending: Pending?

    init(settings: Settings) {
        self.settings = settings
    }

    var isRunning: Bool { tap != nil }

    // MARK: - Ciclo de vida

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }

        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<ClickInterceptor>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        if pending != nil { replay() }
    }

    // MARK: - Manejo de eventos

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // macOS desactiva el tap si tardamos demasiado; lo volvemos a prender.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        // Eventos que reenviamos nosotros: pasan derecho.
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return pass }

        // Mientras activamos una ventana, guardamos todo (drags, mouseUp, segundo click)
        // para reproducirlo en orden después.
        if pending != nil {
            if let copy = event.copy() { pending?.events.append(copy) }
            return nil
        }

        guard settings.enabled, settings.handles(type) else { return pass }

        // Solo ventanas normales (capa 0). Menú, Dock, Centro de control, menús abiertos,
        // popovers y paneles de sistema viven en capas superiores y no se tocan.
        guard let target = WindowLocator.window(at: event.location), target.layer == 0 else { return pass }

        guard let app = NSRunningApplication(processIdentifier: target.pid),
              app.activationPolicy != .prohibited,
              !settings.isExcluded(app.bundleIdentifier) else { return pass }

        guard needsActivation(target) else { return pass }
        guard let copy = event.copy() else { return pass }

        pending = Pending(pid: target.pid, windowID: target.windowID,
                          started: CFAbsoluteTimeGetCurrent(), events: [copy])

        // Salimos del callback rápido y activamos fuera de él.
        DispatchQueue.main.async { [weak self] in self?.beginActivation() }
        return nil
    }

    private func needsActivation(_ target: TargetWindow) -> Bool {
        guard WindowLocator.isFrontmost(target.pid) else { return true }

        // La app ya está al frente: ¿la ventana clickeada es la que tiene el foco?
        guard let focused = WindowLocator.focusedWindowID(of: target.pid) else { return false }
        if focused == target.windowID { return false }

        // Otra ventana de la misma app. Los paneles flotantes (inspectores, paletas)
        // funcionan sin volverse key, así que solo intervenimos en ventanas normales.
        guard let axWindow = WindowLocator.axWindow(pid: target.pid, windowID: target.windowID) else { return false }
        return WindowLocator.isStandardWindow(axWindow)
    }

    // MARK: - Activación y reenvío

    private func beginActivation() {
        guard let pending else { return }
        WindowActivator.activate(pid: pending.pid, windowID: pending.windowID)
        poll()
    }

    private func poll() {
        guard let pending else { return }

        let elapsed = CFAbsoluteTimeGetCurrent() - pending.started
        let active = WindowLocator.isFrontmost(pending.pid)
            && (WindowLocator.focusedWindowID(of: pending.pid).map { $0 == pending.windowID } ?? true)

        let speed = settings.speed
        if active || elapsed > speed.activationTimeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + speed.settleDelay) { [weak self] in self?.replay() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in self?.poll() }
        }
    }

    private func replay() {
        guard let pending else { return }
        self.pending = nil
        for event in pending.events {
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.post(tap: .cgSessionEventTap)
        }
    }
}
