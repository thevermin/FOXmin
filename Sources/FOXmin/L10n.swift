import Foundation

/// Texto traducido al idioma del sistema. La clave es el texto en inglés (el idioma de reserva);
/// las traducciones están en Resources/<idioma>.lproj/Localizable.strings.
func L(_ key: String, _ args: CVarArg...) -> String {
    let text = NSLocalizedString(key, comment: "")
    return args.isEmpty ? text : String(format: text, arguments: args)
}
