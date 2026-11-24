import CryptoKit
import Foundation

// Read the private seed only from stdin; print only its public counterpart.
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let text = String(data: input, encoding: .utf8), let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32 else {
    FileHandle.standardError.write(Data("Expected a base64 encoded 32-byte Sparkle seed.\n".utf8)); exit(1)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(key.publicKey.rawRepresentation.base64EncodedString())
