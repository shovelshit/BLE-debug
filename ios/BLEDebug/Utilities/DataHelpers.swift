// DataHelpers.swift
// Hex / Text conversion utilities (mirrors characteristic.js helpers)

import Foundation

enum DataHelpers {

    /// Convert Data to space-separated uppercase HEX string: "AA BB CC"
    static func toHex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Convert Data to ASCII string (replaces non-printable bytes with '.')
    static func toASCII(_ data: Data) -> String {
        data.map { byte -> Character in
            let scalar = UnicodeScalar(byte)
            return (byte >= 32 && byte < 127) ? Character(scalar) : "."
        }.map(String.init).joined()
    }

    /// Parse "AA BB CC" or "AABBCC" hex string to Data. Throws on invalid input.
    static func hexToData(_ hex: String) throws -> Data {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
                         .replacingOccurrences(of: "\n", with: "")
                         .replacingOccurrences(of: "\t", with: "")
        guard cleaned.count % 2 == 0 else {
            throw DataError.oddLength
        }
        var bytes: [UInt8] = []
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let nextIdx = cleaned.index(idx, offsetBy: 2)
            let byteStr = String(cleaned[idx..<nextIdx])
            guard let byte = UInt8(byteStr, radix: 16) else {
                throw DataError.invalidCharacter(byteStr)
            }
            bytes.append(byte)
            idx = nextIdx
        }
        return Data(bytes)
    }

    /// Convert plain text string to Data (UTF-8)
    static func textToData(_ text: String) -> Data {
        Data(text.utf8)
    }

    enum DataError: LocalizedError {
        case oddLength
        case invalidCharacter(String)

        var errorDescription: String? {
            switch self {
            case .oddLength:              return "十六进制长度必须为偶数"
            case .invalidCharacter(let c): return "无效的十六进制字符: \(c)"
            }
        }
    }
}
