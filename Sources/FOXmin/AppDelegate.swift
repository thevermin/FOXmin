import AppKit
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private lazy var interceptor = ClickInterceptor(settings: settings)
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var permissionTimer: Timer?
    private let updater = UpdateChecker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        // Click: prende o apaga. Click derecho (o control-click): abre el menú.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateIcon()

        if accessibilityTrusted(prompt: true) {
            interceptor.start()
        } else {
            waitForPermission()
        }
        updateIcon()
        updater.startAutomaticChecks { [weak self] in self?.updateIcon() }
    }

    // MARK: - Permisos

    private func accessibilityTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    private func waitForPermission() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, self.accessibilityTrusted(prompt: false) else { return }
            timer.invalidate()
            self.permissionTimer = nil
            self.interceptor.start()
            self.updateIcon()
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Ícono y menú

    private func updateIcon() {
        let active = settings.enabled && interceptor.isRunning
        // Encendido: la silueta llena. Apagado: solo el contorno.
        let image = Bundle.main.image(forResource: active ? "MenuBarIcon" : "MenuBarIconOff")
            ?? NSImage(systemSymbolName: active ? "cursorarrow.click.2" : "cursorarrow",
                       accessibilityDescription: nil)
        image?.isTemplate = true
        image?.accessibilityDescription = active ? "FOXmin: encendido" : "FOXmin: apagado"
        statusItem.button?.image = image
        statusItem.button?.toolTip = active
            ? "FOXmin está encendido · click para apagarlo, click derecho para el menú"
            : "FOXmin está apagado · click para encenderlo, click derecho para el menú"
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        // Sin permiso de Accesibilidad no hay nada que prender: se muestra el menú con el aviso.
        if wantsMenu || !interceptor.isRunning {
            showMenu()
        } else {
            toggleEnabled()
        }
    }

    private func showMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // así el próximo click vuelve a prender o apagar
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Al abrir el menú de una app accesoria, la app del usuario sigue siendo la frontmost.
        let frontApp = NSWorkspace.shared.frontmostApplication

        if let release = updater.available {
            let update = NSMenuItem(title: "⬆︎ Descargar FOXmin \(release.version)…",
                                    action: #selector(openAvailableUpdate), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
            menu.addItem(.separator())
        }

        if !interceptor.isRunning {
            let warning = NSMenuItem(title: "⚠︎ Falta el permiso de Accesibilidad…",
                                     action: #selector(openAccessibilitySettings), keyEquivalent: "")
            warning.target = self
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        menu.addItem(item("Activado", #selector(toggleEnabled), on: settings.enabled))
        menu.addItem(.separator())
        menu.addItem(item("Click derecho también", #selector(toggleRight), on: settings.rightClick))
        menu.addItem(item("Click del medio también", #selector(toggleMiddle), on: settings.middleClick))

        let speedMenu = NSMenu()
        for speed in Settings.Speed.allCases {
            let entry = item(speed.title, #selector(setSpeed(_:)), on: settings.speed == speed)
            entry.representedObject = speed.rawValue
            speedMenu.addItem(entry)
        }
        let speedItem = NSMenuItem(title: "Velocidad de activación", action: nil, keyEquivalent: "")
        speedItem.submenu = speedMenu
        menu.addItem(speedItem)
        menu.addItem(.separator())

        if let frontApp, let bundleID = frontApp.bundleIdentifier,
           bundleID != Bundle.main.bundleIdentifier {
            let name = frontApp.localizedName ?? bundleID
            let excluded = settings.isExcluded(bundleID)
            let toggle = item(excluded ? "Volver a incluir \(name)" : "Excluir \(name)",
                              #selector(toggleExcludedApp(_:)), on: false)
            toggle.representedObject = bundleID
            menu.addItem(toggle)
        }

        let submenu = NSMenu()
        for bundleID in settings.excludedApps.sorted() {
            let entry = item(displayName(for: bundleID), #selector(toggleExcludedApp(_:)), on: true)
            entry.representedObject = bundleID
            entry.toolTip = "Click para volver a incluirla"
            submenu.addItem(entry)
        }
        if !settings.excludedApps.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(item("Agregar app…", #selector(addExcludedApp), on: false))
        let parent = NSMenuItem(title: "Apps excluidas", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)

        menu.addItem(.separator())
        menu.addItem(item("Abrir al iniciar sesión", #selector(toggleLaunchAtLogin),
                          on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item("Acerca de FOXmin", #selector(showAbout), on: false))
        menu.addItem(item("Buscar actualizaciones…", #selector(checkForUpdates), on: false))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir de FOXmin",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    private func displayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    // MARK: - Acciones

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        updateIcon()
    }

    @objc private func toggleRight() { settings.rightClick.toggle() }
    @objc private func toggleMiddle() { settings.middleClick.toggle() }

    @objc private func toggleExcludedApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        settings.toggleExcluded(bundleID)
    }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let speed = Settings.Speed(rawValue: raw) else { return }
        settings.speed = speed
    }

    @objc private func addExcludedApp() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Elegí las apps que FOXmin tiene que ignorar"
        panel.prompt = "Excluir"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                settings.exclude(bundleID)
            }
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "Click-through para macOS: un solo click activa la ventana y hace lo que clickeaste.\n\(UpdateChecker.releasesPage.absoluteString)",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func checkForUpdates() {
        updater.check { [weak self] result in
            guard let self else { return }
            self.updateIcon()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            switch result {
            case .success(let release?):
                alert.messageText = "Hay una versión nueva: FOXmin \(release.version)"
                alert.informativeText = "Tenés la \(UpdateChecker.currentVersion)."
                alert.addButton(withTitle: "Descargar")
                alert.addButton(withTitle: "Más tarde")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.url) }
            case .success(nil):
                alert.messageText = "Estás al día"
                alert.informativeText = "FOXmin \(UpdateChecker.currentVersion) es la última versión."
                alert.runModal()
            case .failure(let error):
                alert.messageText = "No se pudo buscar actualizaciones"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc private func openAvailableUpdate() {
        NSWorkspace.shared.open(updater.available?.url ?? UpdateChecker.releasesPage)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "No se pudo cambiar el inicio automático"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
