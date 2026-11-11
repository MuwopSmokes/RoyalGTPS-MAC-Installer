import Foundation
import Security

@main
enum CheckCertificate {
    static func main() throws {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let certificate = try Certificate.pinned(data)
            let output = URL(fileURLWithPath: CommandLine.arguments[2])
            try (SecCertificateCopyData(certificate) as Data).write(to: output)
        } catch {
            FileHandle.standardError.write(Data("Certificate validation failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
