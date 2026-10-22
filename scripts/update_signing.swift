#!/usr/bin/env swift
import CryptoKit
import Foundation
import Security

// This release utility never exports a private key. Only public-key creates one;
// sign must find the existing key so a missing release key cannot go unnoticed.
private let keyService = "com.atomfilmlab.camera-profile-builder.updates"
private let keyAccount = "Ed25519"

private enum SigningError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

private func keyQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: keyService,
     kSecAttrAccount as String: keyAccount,
     kSecAttrSynchronizable as String: false]
}

private func keychainError(_ operation: String, _ status: OSStatus) -> SigningError {
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    return .message("Could not \(operation) the update signing key in Keychain: \(detail)")
}

private func existingKey() throws -> Curve25519.Signing.PrivateKey? {
    var query = keyQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw keychainError("read", status) }
    guard let bytes = result as? Data,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes) else {
        throw SigningError.message("The update signing key in Keychain is invalid. Restore the original key before publishing another release.")
    }
    return key
}

private func keyForPublicOutput() throws -> Curve25519.Signing.PrivateKey {
    if let key = try existingKey() { return key }
    let key = Curve25519.Signing.PrivateKey()
    var attributes = keyQuery()
    attributes[kSecAttrLabel as String] = "Camera Profile Builder update signing key"
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    attributes[kSecValueData as String] = key.rawRepresentation
    let status = SecItemAdd(attributes as CFDictionary, nil)
    if status == errSecDuplicateItem, let existing = try existingKey() { return existing }
    guard status == errSecSuccess else { throw keychainError("save", status) }
    return key
}

private func requiredSigningKey() throws -> Curve25519.Signing.PrivateKey {
    guard let key = try existingKey() else {
        throw SigningError.message("No Camera Profile Builder update signing key was found. For the first release, run public-key once and embed that public key in the app. For an existing release, restore the original Keychain key; do not create a replacement.")
    }
    return key
}

private func readFile(_ path: String, description: String) throws -> Data {
    do { return try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) }
    catch { throw SigningError.message("Could not read \(description) at \(path).") }
}

private func base64(_ text: String, description: String) throws -> Data {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let bytes = Data(base64Encoded: trimmed) else {
        throw SigningError.message("The \(description) is not valid Base64.")
    }
    return bytes
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "public-key" where arguments.count == 1:
        print(try keyForPublicOutput().publicKey.rawRepresentation.base64EncodedString())
    case "sign" where arguments.count == 2:
        let key = try requiredSigningKey()
        let payload = try readFile(arguments[1], description: "the file to sign")
        let signature = try key.signature(for: payload).base64EncodedString() + "\n"
        let destination = arguments[1] + ".sig"
        do { try Data(signature.utf8).write(to: URL(fileURLWithPath: destination), options: .atomic) }
        catch { throw SigningError.message("Could not write the detached signature at \(destination).") }
        print(destination)
    case "verify" where arguments.count == 4:
        let payload = try readFile(arguments[1], description: "the signed file")
        let encodedSignature = try readFile(arguments[2], description: "the signature")
        guard let signatureText = String(data: encodedSignature, encoding: .utf8) else {
            throw SigningError.message("The detached signature must be a Base64 text file.")
        }
        let signature = try base64(signatureText, description: "signature")
        let publicBytes = try base64(arguments[3], description: "public key")
        guard publicBytes.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicBytes) else {
            throw SigningError.message("The public key must contain exactly 32 Ed25519 bytes.")
        }
        guard signature.count == 64, publicKey.isValidSignature(signature, for: payload) else {
            throw SigningError.message("Signature verification failed.")
        }
        print("Signature verified.")
    default:
        throw SigningError.message("Usage: update_signing.swift public-key | sign FILE | verify FILE SIGNATURE_FILE PUBLIC_KEY_BASE64")
    }
}

do { try run() }
catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
