import CommonCrypto
import Foundation

public enum Authentication {
  public enum Result: UInt8, Sendable {
    case success = 0
    case wrongKey = 1
    case factoryReset = 2
    case differentOnboardingDevice = 3
  }

  public static func challengeResponse(key: Data, nonce: Data) throws -> Data {
    guard key.count == 16 else { throw ProtocolError.invalidKeyLength }
    guard nonce.count == 15 else { throw ProtocolError.invalidNonceLength }
    var output = [UInt8](repeating: 0, count: 32)
    var written = 0
    let status = key.withUnsafeBytes { keyBytes in
      nonce.withUnsafeBytes { nonceBytes in
        CCCrypt(
          CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
          CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
          keyBytes.baseAddress, key.count, nil,
          nonceBytes.baseAddress, nonce.count, &output, output.count, &written)
      }
    }
    guard status == kCCSuccess, written == 16 else {
      throw ProtocolError.encryptionFailed(status)
    }
    return Data(output.prefix(written))
  }
}
