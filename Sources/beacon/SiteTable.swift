import BeaconKit
import Foundation

enum SiteTable {
    static func render(_ sites: [Site]) {
        guard !sites.isEmpty else {
            print("No projects registered yet.")
            print(Output.dim("Run `beacon register <name>` inside a project to claim a domain and a port."))
            return
        }

        let rows = sites.map { site -> (String, String, String, String) in
            let running = PortProbe.isListening(site.port)
            return (
                running ? Output.green("●") : Output.dim("○"),
                site.name,
                site.url,
                String(site.port)
            )
        }

        // Pad on the visible text, not the escaped string.
        let nameWidth = max(7, rows.map(\.1.count).max() ?? 7)
        let urlWidth = max(6, rows.map(\.2.count).max() ?? 6)

        print("")
        print("  \(" ") \(pad(Output.dim("PROJECT"), to: nameWidth, visible: 7)) "
              + "\(pad(Output.dim("URL"), to: urlWidth, visible: 3)) \(Output.dim("PORT"))")
        for row in rows {
            print("  \(row.0) \(pad(row.1, to: nameWidth, visible: row.1.count)) "
                  + "\(pad(row.2, to: urlWidth, visible: row.2.count)) \(row.3)")
        }
        print("")
    }

    private static func pad(_ text: String, to width: Int, visible: Int) -> String {
        text + String(repeating: " ", count: max(0, width - visible))
    }
}
