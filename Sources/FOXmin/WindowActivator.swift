import AppKit
import ApplicationServices

enum WindowActivator {
    /// Trae al frente la app `pid` y convierte en key a la ventana `windowID`.
    static func activate(pid: pid_t, windowID: CGWindowID) {
        var psn = ProcessSerialNumber()
        if GetProcessForPID(pid, &psn) == noErr {
            // Camino principal: el mismo que usa el WindowServer cuando el usuario hace click.
            _SLPSSetFrontProcessWithOptions(&psn, windowID, SLPSMode.userGenerated.rawValue)
            makeKeyWindow(&psn, windowID: windowID)
        } else if let app = NSRunningApplication(processIdentifier: pid) {
            // Respaldo con API pública.
            app.activate(options: [])
            AXUIElementSetAttributeValue(WindowLocator.appElement(pid),
                                         kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }

        if let window = WindowLocator.axWindow(pid: pid, windowID: windowID) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    /// Le dice al proceso que su ventana `windowID` pasa a ser la key window.
    /// El formato del event record es el que documentaron proyectos como AltTab y yabai.
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, windowID: CGWindowID) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { src in
            for i in 0..<4 { bytes[0x3c + i] = src[i] }
        }
        for i in 0x20..<0x30 { bytes[i] = 0xff }

        bytes[0x08] = 0x01
        bytes.withUnsafeMutableBufferPointer { buf in
            _ = SLPSPostEventRecordTo(&psn, buf.baseAddress!)
        }
        bytes[0x08] = 0x02
        bytes.withUnsafeMutableBufferPointer { buf in
            _ = SLPSPostEventRecordTo(&psn, buf.baseAddress!)
        }
    }
}
