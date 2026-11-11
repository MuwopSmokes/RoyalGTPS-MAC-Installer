import Foundation

@main
enum HostsTests {
    static func expect(_ actual: @autoclosure () throws -> String, _ expected: String,
                       _ scenario: String) throws {
        guard try actual().utf8.elementsEqual(expected.utf8) else {
            throw SetupError("Fixture failed: \(scenario)")
        }
    }

    static func fixture(_ name: String) throws -> String {
        try String(contentsOfFile: "Tests/hosts-\(name).txt", encoding: .utf8)
    }

    static func main() throws {
        let before = try fixture("before")
        let installed = try fixture("installed")
        let later = try fixture("later")
        let restored = try fixture("restored")
        try expect(Hosts.install(before), installed, "replace exact hosts, preserving aliases and comments")
        try expect(Hosts.install(installed), installed, "reinstall is idempotent")
        try expect(Hosts.undo(current: installed, before: before, after: installed), before, "exact rollback")
        try expect(Hosts.undo(current: before, before: before, after: installed), before, "write never occurred")
        try expect(Hosts.undo(current: later, before: before, after: installed), restored, "undo preserves later edits")
        guard Hosts.verified(installed), Hosts.verified(later), !Hosts.verified(before) else {
            throw SetupError("Mapping verification failed.")
        }
        let conflict = later.replacingOccurrences(of: "15.235.167.45 www.growtopia2.com",
                                                   with: "10.1.2.3 www.growtopia2.com")
        do {
            _ = try Hosts.undo(current: conflict, before: before, after: installed)
            throw SetupError("Expected a conflict for a later target edit.")
        } catch let error as SetupError where error.message.hasPrefix("A Growtopia mapping changed") {}

        let mixed = "127.0.0.1 localhost\r\n\t::1\tWWW.GROWTOPIA1.COM\tneighbor  # café"
        let mixedAfter = "127.0.0.1 localhost\r\n\t::1\tneighbor  # café\r\n"
            + "15.235.167.45 www.growtopia1.com\r\n15.235.167.45 www.growtopia2.com\r\n"
        try expect(Hosts.install(mixed), mixedAfter, "CRLF, tabs, UTF-8, and missing final newline")
        try expect(Hosts.undo(current: mixedAfter, before: mixed, after: mixedAfter), mixed, "byte-for-byte mixed rollback")
        try expect(Hosts.undo(current: Hosts.install(""), before: "", after: Hosts.install("")), "", "empty file rollback")
        print("Hosts fixtures passed.")
    }
}
