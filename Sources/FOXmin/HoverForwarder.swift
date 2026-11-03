import AppKit

/// Hover en ventanas de fondo (experimental).
///
/// Le pasa el movimiento del mouse a la app de la ventana que está debajo del cursor, aunque no
/// esté activa, para que reaccione como en Windows (por ejemplo, los controles de un video).
/// No activa nada ni cambia el foco: el teclado sigue donde estaba.
///
/// Pensado para gastar lo mínimo:
/// - un event tap de solo escucha (no puede demorar el cursor ni bloquear nada);
/// - si el mouse está quieto no llegan eventos, así que no se hace nada: sin timers;
/// - como mucho 60 reenvíos por segundo;
/// - la lista de ventanas se guarda y se renueva como mucho 4 veces por segundo,
///   y solo mientras el mouse se mueve.
final class HoverForwarder {
    private struct Win {
        let frame: CGRect
        let pid: pid_t
        let id: CGWindowID
        let layer: Int
        let excluded: Bool
    }

    private let settings: Settings
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var observer: NSObjectProtocol?

    private var windows: [Win] = []
    private var windowsTime: CFAbsoluteTime = 0
    private var lastSent: CFAbsoluteTime = 0
    private var frontPID: pid_t = 0
    private var hovered: Win?

    private let minInterval: CFTimeInterval = 1.0 / 60
    private let listLifetime: CFTimeInterval = 0.25

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
                Unmanaged<HoverForwarder>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
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
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontPID = app?.processIdentifier ?? 0
            self?.windowsTime = 0
            self?.hovered = nil
        }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        tap = nil
        source = nil
        observer = nil
        hovered = nil
        windows = []
    }

    // MARK: - Movimiento

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .mouseMoved, settings.enabled,
              event.getIntegerValueField(.eventSourceUserData) != ClickInterceptor.marker else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSent >= minInterval else { return }
        lastSent = now

        let point = event.location
        let target = window(at: point, now: now)

        // El cursor salió de la ventana de fondo que estábamos alimentando: le avisamos.
        if let previous = hovered, previous.id != target?.id {
            sendExit(from: previous, basedOn: event)
            hovered = nil
        }

        guard let target, target.pid != frontPID, !target.excluded else { return }
        hovered = target
        forward(event, to: target, at: point)
    }

    private func window(at point: CGPoint, now: CFAbsoluteTime) -> Win? {
        if now - windowsTime > listLifetime { refreshWindows(now: now) }
        // Ordenadas de adelante hacia atrás: la primera que contiene el punto es la visible.
        // Si es un menú, el Dock u otra capa del sistema, no se reenvía nada.
        guard let top = windows.first(where: { $0.frame.contains(point) }), top.layer == 0 else { return nil }
        return top
    }

    private func refreshWindows(now: CFAbsoluteTime) {
        windowsTime = now
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            windows = []
            return
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var excludedByPID: [pid_t: Bool] = [:]
        windows = list.compactMap { info in
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  pid != myPID else { return nil }
            if ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) < 0.01 { return nil }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let excluded: Bool
            if let cached = excludedByPID[pid] {
                excluded = cached
            } else {
                excluded = settings.isExcluded(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
                excludedByPID[pid] = excluded
            }
            return Win(frame: frame, pid: pid, id: id, layer: layer, excluded: excluded)
        }
    }

    private func forward(_ event: CGEvent, to win: Win, at point: CGPoint) {
        guard let copy = event.copy() else { return }
        copy.location = point
        copy.setIntegerValueField(.eventSourceUserData, value: ClickInterceptor.marker)
        copy.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(win.id))
        copy.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(win.id))
        copy.postToPid(win.pid)
    }

    /// Un último movimiento justo afuera de la ventana, para que la app sepa que el mouse se fue
    /// (si no, por ejemplo, los controles del video quedarían visibles).
    private func sendExit(from win: Win, basedOn event: CGEvent) {
        forward(event, to: win, at: CGPoint(x: win.frame.minX - 4, y: win.frame.minY - 4))
    }
}
