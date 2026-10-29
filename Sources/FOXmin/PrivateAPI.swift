import AppKit
import ApplicationServices

// APIs privadas (no documentadas) de macOS. Son las mismas que usan proyectos
// open source como AltTab y yabai para activar una ventana puntual de otra app,
// cosa que las APIs públicas no permiten hacer de forma confiable desde macOS 14.

/// Devuelve el CGWindowID de un AXUIElement de tipo ventana.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("GetProcessForPID")
@discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

/// Trae un proceso al frente enfocando una ventana específica.
@_silgen_name("_SLPSSetFrontProcessWithOptions")
@discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ windowID: CGWindowID, _ mode: UInt32) -> CGError

/// Envía un "event record" crudo del WindowServer a un proceso.
@_silgen_name("SLPSPostEventRecordTo")
@discardableResult
func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

enum SLPSMode: UInt32 {
    case allWindows = 0x100
    case userGenerated = 0x200
    case noWindows = 0x400
}
