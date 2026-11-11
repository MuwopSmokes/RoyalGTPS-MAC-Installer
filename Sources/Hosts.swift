import Foundation
import Darwin

struct SetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Hosts {
    static let address = "15.235.167.45"
    static let names = ["www.growtopia1.com", "www.growtopia2.com"]
    static let token = try! NSRegularExpression(pattern: #"[^ \t\r]+"#)

    struct Line {
        let body: String
        let ending: String

        var code: NSString {
            (body.components(separatedBy: "#")[0]) as NSString
        }

        var fields: [NSTextCheckingResult] {
            token.matches(in: code as String, range: NSRange(location: 0, length: code.length))
        }

        var address: String? {
            guard let first = fields.first else { return nil }
            let value = code.substring(with: first.range)
            var ipv4 = in_addr()
            var ipv6 = in6_addr()
            return inet_pton(AF_INET, value, &ipv4) == 1 || inet_pton(AF_INET6, value, &ipv6) == 1
                ? value : nil
        }

        var aliases: [String] {
            guard address != nil else { return [] }
            return fields.dropFirst().map { code.substring(with: $0.range) }
        }

        func removing(_ namesToRemove: Set<String>) -> String {
            let matches = fields
            let aliases = self.aliases
            let indexes = aliases.indices.filter { namesToRemove.contains(aliases[$0].lowercased()) }
            guard !indexes.isEmpty else { return body + ending }
            if indexes.count == aliases.count {
                guard let comment = body.firstIndex(of: "#") else { return "" }
                return String(body[comment...]) + ending
            }
            let result = NSMutableString(string: body)
            for index in indexes.reversed() {
                let start = NSMaxRange(matches[index].range)
                let end = NSMaxRange(matches[index + 1].range)
                result.deleteCharacters(in: NSRange(location: start, length: end - start))
            }
            return (result as String) + ending
        }
    }

    static func lines(_ contents: String) -> [Line] {
        let bytes = Array(contents.utf8)
        var start = 0
        var result: [Line] = []
        for index in bytes.indices where bytes[index] == 10 {
            let crlf = index > start && bytes[index - 1] == 13
            let end = crlf ? index - 1 : index
            result.append(Line(body: String(decoding: bytes[start..<end], as: UTF8.self),
                               ending: crlf ? "\r\n" : "\n"))
            start = index + 1
        }
        if start < bytes.count {
            result.append(Line(body: String(decoding: bytes[start...], as: UTF8.self), ending: ""))
        }
        return result
    }

    static func appending(_ rows: [String], to contents: String) -> String {
        guard !rows.isEmpty else { return contents }
        let separator = lines(contents).first { !$0.ending.isEmpty }?.ending ?? "\n"
        let needsSeparator = !contents.isEmpty && contents.utf8.last != 10
        return contents + (needsSeparator ? separator : "") + rows.joined(separator: separator) + separator
    }

    static func install(_ contents: String) -> String {
        let cleaned = lines(contents).map { $0.removing(Set(names)) }.joined()
        return appending(names.map { "\(address) \($0)" }, to: cleaned)
    }

    static func mappings(_ name: String, in contents: String) -> [String] {
        lines(contents).flatMap { line in
            line.aliases.filter { $0.lowercased() == name }.compactMap { _ in line.address }
        }
    }

    static func verified(_ contents: String) -> Bool {
        names.allSatisfy { mappings($0, in: contents) == [address] }
    }

    static func undo(current: String, before: String, after: String) throws -> String {
        if current.utf8.elementsEqual(before.utf8) { return current }
        if current.utf8.elementsEqual(after.utf8) { return before }
        guard verified(current) else {
            throw SetupError("A Growtopia mapping changed after setup. Review /etc/hosts before retrying Undo Setup.")
        }

        let namesToRestore = Set(names)
        let cleaned = lines(current).map { $0.removing(namesToRestore) }.joined()
        let originalMappings = lines(before).compactMap { line -> String? in
            let aliases = line.aliases.filter { namesToRestore.contains($0.lowercased()) }
            guard let address = line.address, !aliases.isEmpty else { return nil }
            return ([address] + aliases).joined(separator: " ")
        }
        return appending(originalMappings, to: cleaned)
    }
}
