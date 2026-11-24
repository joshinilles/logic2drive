import Foundation
let ziel = URL(fileURLWithPath: CommandLine.arguments[1])
let neu = URL(fileURLWithPath: CommandLine.arguments[2])
var fehler: NSError?
var ergebnis = "nicht ausgeführt"
NSFileCoordinator().coordinate(writingItemAt: ziel, options: .forReplacing, error: &fehler) { z in
    do { _ = try FileManager.default.replaceItemAt(z, withItemAt: neu); ergebnis = "ersetzt" }
    catch { ergebnis = "Fehler: \(error)" }
}
if let fehler { print("Koordination: \(fehler)") }
print(ergebnis)
