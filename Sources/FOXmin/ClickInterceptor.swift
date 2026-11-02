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
        let app: NSRunningApplication
        let started: CFAbsoluteTime
        var events: [CGEvent]
    }

    /// Movimiento mínimo (en puntos) para considerar que hubo un arrastre de verdad.
    private let dragThreshold: CGFloat = 4
    /// Dos clicks más juntos que esto, y en el mismo lugar, son un doble click de verdad.
    /// Si el segundo llega más tarde, es alguien que volvió a clickear porque "no pasó nada".
    private let doubleClickWindow: CFTimeInterval = 0.25

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

        pending = Pending(pid: target.pid, windowID: target.windowID, app: app,
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
        let speed = settings.speed
        if isReady(pending) || elapsed > speed.activationTimeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + speed.settleDelay) { [weak self] in self?.replay() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in self?.poll() }
        }
    }

    /// La ventana está lista cuando la propia app ya se enteró de que está activa (no solo el
    /// WindowServer) y la ventana clickeada es la que tiene el foco. Si esa "ventana" es una capa
    /// interna que Accesibilidad no conoce (pasa en Chrome y Electron), alcanza con que la app esté activa.
    private func isReady(_ pending: Pending) -> Bool {
        guard pending.app.isActive, WindowLocator.isFrontmost(pending.pid) else { return false }
        if WindowLocator.focusedWindowID(of: pending.pid) == pending.windowID { return true }
        return WindowLocator.axWindow(pid: pending.pid, windowID: pending.windowID) == nil
    }

    private func replay() {
        guard let first = pending?.events.first else { pending = nil; return }

        // El mouseDown va primero y solo; el resto un instante después, para que la app procese
        // el click antes del mouseUp. Mientras tanto, lo que llegue se sigue guardando.
        first.setIntegerValueField(.mouseEventClickState, value: 1)
        post(first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) { [weak self] in
            guard let self, let current = self.pending else { return }
            self.pending = nil
            for event in self.cleaned(current.events).dropFirst() { self.post(event) }
        }
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.post(tap: .cgSessionEventTap)
    }

    /// Limpia lo que se juntó mientras se activaba la ventana:
    /// - el primer click se reenvía como click simple;
    /// - los movimientos mínimos durante el click se descartan (si no, seleccionan texto);
    /// - un click extra que llegó tarde es alguien reintentando: se descarta entero
    ///   (si no, la app lo recibe como doble click). Un doble click rápido de verdad se respeta.
    private func cleaned(_ events: [CGEvent]) -> [CGEvent] {
        guard let first = events.first else { return [] }
        let origin = first.location
        let distance = { (e: CGEvent) in hypot(e.location.x - origin.x, e.location.y - origin.y) }
        let isDown = { (e: CGEvent) in [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(e.type) }
        let isUp = { (e: CGEvent) in [CGEventType.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(e.type) }
        let isDrag = { (e: CGEvent) in [CGEventType.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(e.type) }

        // ¿Hubo un arrastre real durante el primer click?
        var firstClick: [CGEvent] = []
        for e in events { firstClick.append(e); if isUp(e) { break } }
        let realDrag = firstClick.contains { isDrag($0) && distance($0) >= dragThreshold }

        var result: [CGEvent] = []
        var clickIndex = 0          // 0 = primer click, 1 = segundo…
        var dropping = false        // estamos salteando un click de "reintento"
        for e in events {
            if isDown(e) {
                if result.isEmpty {
                    clickIndex = 0
                } else {
                    clickIndex += 1
                    let gap = Double(e.timestamp &- first.timestamp) / 1_000_000_000
                    let genuineDouble = gap <= doubleClickWindow && distance(e) < dragThreshold
                    dropping = !genuineDouble
                    if dropping { continue }
                }
            }
            if dropping { if isUp(e) { dropping = false }; continue }
            if isDrag(e) && clickIndex == 0 && !realDrag { continue }
            if clickIndex == 0 && (isDown(e) || isUp(e)) {
                e.setIntegerValueField(.mouseEventClickState, value: 1)
            }
            result.append(e)
        }
        return result
    }
}
