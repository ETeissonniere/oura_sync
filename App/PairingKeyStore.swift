import Foundation
import Security

struct PairingKeyStore {
  enum Failure: Error {
    case keychain(OSStatus)
    case invalidKey
  }

  private let service = "app.ourasync.ring-auth"

  func load(for peripheralID: UUID) throws -> Data? {
    var query = attributes(for: peripheralID)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw Failure.keychain(status) }
    guard let data = item as? Data, data.count == 16 else { throw Failure.invalidKey }
    return data
  }

  // Persist before sending SetAuthKey. A disconnect or process termination after
  // installation must not strand the ring with an unknown key.
  func existingOrCreate(for peripheralID: UUID) throws -> Data {
    if let existing = try load(for: peripheralID) { return existing }
    var bytes = [UInt8](repeating: 0, count: 16)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else { throw Failure.keychain(status) }
    let key = Data(bytes)
    var query = attributes(for: peripheralID)
    query[kSecValueData] = key
    query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let saveStatus = SecItemAdd(query as CFDictionary, nil)
    if saveStatus == errSecDuplicateItem, let existing = try load(for: peripheralID) {
      return existing
    }
    guard saveStatus == errSecSuccess else { throw Failure.keychain(saveStatus) }
    return key
  }

  private func attributes(for peripheralID: UUID) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: peripheralID.uuidString, kSecAttrSynchronizable: false,
    ]
  }
}
