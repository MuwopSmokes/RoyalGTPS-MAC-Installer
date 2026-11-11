import Foundation
import Darwin
import Security

struct HostsChange: Codable {
    let before: String
    let after: String
    var undoSource: String?
    var undoResult: String?
}

struct Journal: Codable {
    let certificate: Data
    var removeCertificate: Bool
    var removeTrust: Bool
    var hosts: HostsChange?
    var refreshOnUndo = false
    var complete = false
    var pendingInstall: UUID?
    var foregroundOwner: pid_t?
}

enum Installer {
    static let stateDirectory = URL(fileURLWithPath: "/var/db/com.royalgtps.setup", isDirectory: true)
    static let stateFile = stateDirectory.appendingPathComponent("recovery.json")
    static let progressFile = stateDirectory.appendingPathComponent("progress")
    static let hostsFile = URL(fileURLWithPath: "/private/etc/hosts")

    static func run(_ path: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SetupError("\(URL(fileURLWithPath: path).lastPathComponent) failed (\(process.terminationStatus)). \(details)")
        }
        return data
    }

    static func growtopiaIsRunning() throws -> Bool {
        let processes = try run("/bin/ps", ["-Aww", "-o", "comm="])
        return String(decoding: processes, as: UTF8.self).split(separator: "\n").contains { line in
            line.split(separator: "/").contains { component in
                ["growtopia", "growtopia.app", "growtopia.bin", "growtopia.exe"].contains(
                    component.trimmingCharacters(in: .whitespaces).lowercased())
            }
        }
    }

    static func withLock(_ action: () throws -> String) throws -> String {
        guard geteuid() == 0 else { throw SetupError("Administrator authentication is required.") }
        if mkdir(stateDirectory.path, 0o755) != 0, errno != EEXIST {
            throw SetupError("Could not create the recovery directory.")
        }
        var info = stat()
        guard lstat(stateDirectory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == 0, info.st_mode & 0o022 == 0 else {
            throw SetupError("The recovery directory is not secured.")
        }
        let lock = open(stateDirectory.appendingPathComponent("lock").path, O_CREAT | O_NOFOLLOW | O_RDWR, 0o600)
        guard lock >= 0 else { throw SetupError("Could not open the setup lock.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw SetupError("Another setup operation is running.") }
        guard try !growtopiaIsRunning() else { throw SetupError("Close Growtopia before continuing.") }
        return try action()
    }

    static func load() throws -> Journal? {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return nil }
        return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: stateFile))
    }

    static func save(_ journal: Journal) throws {
        // The directory permits players to detect the journal. Its contents are root-only.
        try replace(stateFile, data: JSONEncoder().encode(journal), mode: 0o600, uid: 0, gid: 0)
    }

    static func replace(_ url: URL, data: Data, mode: mode_t, uid: uid_t, gid: gid_t,
                        preserveMetadataFrom source: Int32? = nil,
                        validate: () throws -> Void = {}) throws {
        var template = Array(url.deletingLastPathComponent().appendingPathComponent(".royal-gtps.XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw SetupError("Could not create a temporary file for \(url.lastPathComponent).") }
        let temporary = String(cString: template)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { unlink(temporary) }
        try handle.write(contentsOf: data)
        guard fchown(descriptor, uid, gid) == 0, fchmod(descriptor, mode) == 0 else {
            throw SetupError("Could not save \(url.lastPathComponent) with its permissions.")
        }
        if let source, fcopyfile(source, descriptor, nil, UInt32(COPYFILE_ACL | COPYFILE_XATTR)) != 0 {
            throw SetupError("Could not preserve /etc/hosts metadata.")
        }
        guard fsync(descriptor) == 0 else { throw SetupError("Could not flush \(url.lastPathComponent) to disk.") }
        try validate()
        guard rename(temporary, url.path) == 0 else { throw SetupError("Could not replace \(url.lastPathComponent).") }
    }

    static func reportVerification(_ operation: UUID?) {
        guard let operation else { return }
        // Progress is advisory. A status update must never prevent recovery.
        try? replace(progressFile, data: Data(operation.uuidString.utf8), mode: 0o644, uid: 0, gid: 0)
    }

    static func readHosts() throws -> String {
        let data = try Data(contentsOf: hostsFile)
        guard let contents = String(data: data, encoding: .utf8), !contents.utf8.contains(0) else {
            throw SetupError("/etc/hosts must be a UTF-8 text file.")
        }
        return contents
    }

    static func writeHosts(_ contents: String, replacing expected: String) throws {
        let original = open(hostsFile.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard original >= 0 else { throw SetupError("Could not open /etc/hosts for editing.") }
        defer { close(original) }
        var info = stat()
        guard fstat(original, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw SetupError("/etc/hosts must be a regular file.")
        }
        try replace(hostsFile, data: Data(contents.utf8), mode: info.st_mode & 0o7777,
                    uid: info.st_uid, gid: info.st_gid, preserveMetadataFrom: original) {
            var current = stat()
            guard lstat(hostsFile.path, &current) == 0, current.st_ino == info.st_ino,
                  current.st_dev == info.st_dev, current.st_mode == info.st_mode,
                  current.st_uid == info.st_uid, current.st_gid == info.st_gid,
                  try readHosts().utf8.elementsEqual(expected.utf8) else {
                throw SetupError("/etc/hosts changed during setup. Retry after the other edit finishes.")
            }
        }
    }

    static func refreshDNS() throws {
        _ = try run("/usr/bin/dscacheutil", ["-flushcache"])
        _ = try run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    static func resolves(_ hostname: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(first) }
        var expected = in_addr()
        guard inet_pton(AF_INET, Hosts.address, &expected) == 1 else { return false }
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let current = entry {
            guard let address = current.pointee.ai_addr,
                  Int(current.pointee.ai_addrlen) >= MemoryLayout<sockaddr_in>.size,
                  address.withMemoryRebound(to: sockaddr_in.self, capacity: 1, {
                      $0.pointee.sin_addr.s_addr == expected.s_addr
                  }) else { return false }
            entry = current.pointee.ai_next
        }
        return true
    }

    static func verifyHosts() throws {
        guard try Hosts.verified(readHosts()) else { throw SetupError("Could not verify the Growtopia hosts mappings.") }
        for _ in 0..<5 {
            if Hosts.names.allSatisfy(resolves) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw SetupError("macOS did not resolve both Growtopia hostnames to \(Hosts.address).")
    }

    static func prepareInstall(_ data: Data, owner: pid_t) throws -> String {
        let certificate = try Certificate.pinned(data)
        let system = try SystemCertificate(certificate)
        if let existing = try load() {
            guard existing.complete else { throw SetupError("A setup attempt is unfinished. Select Return to Original Growtopia before installing again.") }
            do {
                try system.verify()
                try verifyHosts()
            } catch {
                throw SetupError("The previous setup could not be verified. \(error.localizedDescription) Select Return to Original Growtopia to restore it.")
            }
            return "Setup complete"
        }

        let item = try system.item()
        let settings = try system.trust()
        if let settings {
            guard item != nil else {
                throw SetupError("macOS has a saved trust setting for this certificate, but the certificate is missing from the System keychain. Import the Royal GTPS certificate into System and try again.")
            }
            guard system.acceptsExistingSSLTrust(settings) else {
                throw SetupError("The Royal GTPS certificate has custom trust settings. Set Secure Sockets Layer (SSL) to Always Trust in the System keychain, then try again.")
            }
        }
        var journal = Journal(certificate: SecCertificateCopyData(certificate) as Data,
                              removeCertificate: item == nil, removeTrust: settings == nil)
        _ = try readHosts()
        let operation = UUID()
        journal.pendingInstall = operation
        journal.foregroundOwner = owner
        try save(journal)
        do {
            if journal.removeCertificate { try system.add() }
        } catch {
            let failure = error.localizedDescription
            do {
                _ = try undo(&journal)
            } catch {
                throw SetupError("\(failure) Recovery needs attention. \(error.localizedDescription)")
            }
            throw SetupError("\(failure) Changes from this attempt were rolled back.")
        }
        return "PREPARED:\(operation.uuidString):\(journal.removeTrust ? "trust" : "trusted")"
    }

    static func finishInstall(_ operation: UUID, owner: pid_t) throws -> String {
        guard var journal = try load(), journal.pendingInstall == operation, journal.foregroundOwner == owner else {
            throw SetupError("This setup attempt is no longer active.")
        }
        let system = try SystemCertificate(Certificate.pinned(journal.certificate))
        try system.verify()
        let before = try readHosts()
        let after = Hosts.install(before)
        if !before.utf8.elementsEqual(after.utf8) {
            journal.hosts = HostsChange(before: before, after: after)
            journal.refreshOnUndo = true
            try save(journal)
            do {
                try writeHosts(after, replacing: before)
            } catch {
                // A failed replace has not renamed its temporary file over /etc/hosts.
                journal.hosts = nil
                journal.refreshOnUndo = false
                try save(journal)
                throw error
            }
        }
        reportVerification(operation)
        try refreshDNS()
        try system.verify()
        try verifyHosts()
        journal.refreshOnUndo = true
        journal.complete = true
        journal.pendingInstall = nil
        journal.foregroundOwner = nil
        try save(journal)
        return "Setup complete"
    }

    static func requestUndo(_ journal: inout Journal, owner: pid_t, progress: UUID? = nil) throws -> String {
        if let other = journal.foregroundOwner, other != owner, kill(other, 0) == 0,
           let process = try? run("/bin/ps", ["-ww", "-p", String(other), "-o", "comm="]),
           URL(fileURLWithPath: String(decoding: process, as: UTF8.self)
               .trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent == "RoyalGTPSSetup" {
            throw SetupError("Another Royal GTPS Setup window is handling recovery. Finish or close that window first.")
        }
        if journal.removeTrust {
            let system = try SystemCertificate(Certificate.parse(journal.certificate))
            if let settings = try system.trust(), system.isSetupTrust(settings) {
                // Invalidate any outstanding install before requesting approval in the app.
                journal.complete = false
                journal.pendingInstall = nil
                journal.foregroundOwner = owner
                try save(journal)
                return "REMOVE_TRUST:" + journal.certificate.base64EncodedString()
            }
        }
        return try undo(&journal, progress: progress)
    }

    static func undo(_ journal: inout Journal, progress: UUID? = nil) throws -> String {
        journal.complete = false
        journal.pendingInstall = nil
        journal.foregroundOwner = nil
        try save(journal)
        var issues: [String] = []

        if var change = journal.hosts {
            do {
                let current = try readHosts()
                let restored: String
                if let undoResult = change.undoResult, current.utf8.elementsEqual(undoResult.utf8) {
                    restored = current
                } else if let undoSource = change.undoSource, let undoResult = change.undoResult,
                          current.utf8.elementsEqual(undoSource.utf8) {
                    restored = undoResult
                } else {
                    restored = try Hosts.undo(current: current, before: change.before, after: change.after)
                }
                if !restored.utf8.elementsEqual(current.utf8) {
                    change.undoSource = current
                    change.undoResult = restored
                    journal.hosts = change
                    try save(journal)
                    try writeHosts(restored, replacing: current)
                }
                let verified = try readHosts()
                guard Hosts.names.allSatisfy({ Hosts.mappings($0, in: verified) == Hosts.mappings($0, in: change.before) }) else {
                    throw SetupError("Could not verify the restored Growtopia addresses.")
                }
                journal.hosts = nil
                try save(journal)
            } catch {
                issues.append("Hosts: \(error.localizedDescription)")
            }
        }

        if journal.removeTrust || journal.removeCertificate {
            do {
                let system = try SystemCertificate(Certificate.parse(journal.certificate))
                if let settings = try system.trust() {
                    guard journal.removeTrust, system.isSetupTrust(settings) else {
                        throw SetupError("Certificate trust changed after setup. Setup left that trust in place.")
                    }
                    throw SetupError("SSL trust still needs approval to remove. Retry Return to Original Growtopia.")
                }
                journal.removeTrust = false
                try save(journal)
                if journal.removeCertificate, let item = try system.item() {
                    try system.remove(item)
                    guard try system.item() == nil else { throw SetupError("Could not verify removal from the System keychain.") }
                }
                journal.removeCertificate = false
                try save(journal)
            } catch {
                issues.append("Certificate: \(error.localizedDescription)")
            }
        }

        if issues.isEmpty { reportVerification(progress) }
        if journal.refreshOnUndo && journal.hosts == nil {
            do {
                try refreshDNS()
                journal.refreshOnUndo = false
                try save(journal)
            } catch {
                issues.append("DNS: \(error.localizedDescription)")
            }
        }
        guard issues.isEmpty else { throw SetupError(issues.joined(separator: "\n")) }
        try FileManager.default.removeItem(at: stateFile)
        return "Setup undone"
    }
}

@main
enum Helper {
    static func main() {
        umask(0o022)
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "prepare" || arguments.first == "finish", BuildPin.sha256.isEmpty {
                throw SetupError("Install is disabled pending the independently confirmed certificate fingerprint.")
            }
            let message = try Installer.withLock {
                guard arguments.count >= 2, let owner = pid_t(arguments[1]), owner > 1 else {
                    throw SetupError("Invalid setup window.")
                }
                switch arguments.first {
                case "prepare" where arguments.count == 2:
                    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                    let resources = helper.deletingLastPathComponent().deletingLastPathComponent()
                        .appendingPathComponent("Resources")
                    return try Installer.prepareInstall(Data(contentsOf: resources.appendingPathComponent("RoyalGTPS.crt")), owner: owner)
                case "finish" where arguments.count == 3:
                    guard let operation = UUID(uuidString: arguments[2]) else { throw SetupError("Invalid setup attempt.") }
                    return try Installer.finishInstall(operation, owner: owner)
                case "undo" where arguments.count == 3:
                    guard let progress = UUID(uuidString: arguments[2]) else { throw SetupError("Invalid restore attempt.") }
                    guard var journal = try Installer.load() else { return "No setup to restore" }
                    return try Installer.requestUndo(&journal, owner: owner, progress: progress)
                case "rollback" where arguments.count == 3:
                    guard let operation = UUID(uuidString: arguments[2]),
                          var journal = try Installer.load(), journal.pendingInstall == operation,
                          journal.foregroundOwner == owner else {
                        throw SetupError("This setup attempt is no longer active.")
                    }
                    return try Installer.requestUndo(&journal, owner: owner)
                case "finish-undo" where arguments.count == 3:
                    guard let progress = UUID(uuidString: arguments[2]) else { throw SetupError("Invalid restore attempt.") }
                    guard var journal = try Installer.load(), !journal.complete, journal.pendingInstall == nil,
                          journal.foregroundOwner == owner else {
                        throw SetupError("There is no pending undo to finish.")
                    }
                    return try Installer.undo(&journal, progress: progress)
                default:
                    throw SetupError("Invalid setup operation.")
                }
            }
            print(message)
        } catch {
            FileHandle.standardError.write(Data(error.localizedDescription.utf8))
            exit(1)
        }
    }
}
