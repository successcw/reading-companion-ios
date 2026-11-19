import CryptoKit
import Foundation

struct TencentASRConfig {
    let secretId: String
    let secretKey: String
    let region: String

    var isConfigured: Bool {
        !secretId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum TencentASRError: LocalizedError {
    case missingCredentials
    case invalidResponse
    case api(code: String, message: String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "未配置腾讯云 SecretId / SecretKey"
        case .invalidResponse:
            return "腾讯云返回了无法解析的结果"
        case let .api(code, message):
            return "腾讯云识别失败（\(code)）：\(message)"
        case let .http(status):
            return "腾讯云请求失败（HTTP \(status)）"
        }
    }
}

final class TencentASRClient {
    private let host = "asr.tencentcloudapi.com"
    private let service = "asr"
    private let action = "SentenceRecognition"
    private let version = "2019-06-14"

    func transcribe(wav: Data,
                    config: TencentASRConfig,
                    completion: @escaping (Result<String, Error>) -> Void) {
        guard config.isConfigured else {
            completion(.failure(TencentASRError.missingCredentials))
            return
        }

        // Keep the request to the documented core fields. Optional filters
        // vary by API version; unsupported keys make Tencent reject the whole
        // request with UnknownParameter.
        let payload: [String: Any] = [
            "ProjectId": 0,
            "SubServiceType": 2,
            "EngSerViceType": "16k_zh",
            "SourceType": 1,
            "VoiceFormat": "wav",
            "Data": wav.base64EncodedString(),
            "DataLen": wav.count
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(TencentASRError.invalidResponse))
            return
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let date = Self.dateString(timestamp)
        let contentType = "application/json; charset=utf-8"
        let signedHeaders = "content-type;host"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\n"
        let hashedPayload = Self.sha256Hex(body)
        let canonicalRequest = [
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            hashedPayload
        ].joined(separator: "\n")

        let credentialScope = "\(date)/\(service)/tc3_request"
        let stringToSign = [
            "TC3-HMAC-SHA256",
            "\(timestamp)",
            credentialScope,
            Self.sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let secretDate = Self.hmacSHA256(key: Data("TC3\(config.secretKey)".utf8),
                                         message: Data(date.utf8))
        let secretService = Self.hmacSHA256(key: secretDate, message: Data(service.utf8))
        let secretSigning = Self.hmacSHA256(key: secretService, message: Data("tc3_request".utf8))
        let signature = Self.hex(Self.hmacSHA256(key: secretSigning, message: Data(stringToSign.utf8)))
        let authorization = "TC3-HMAC-SHA256 Credential=\(config.secretId)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: URL(string: "https://\(host)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(action, forHTTPHeaderField: "X-TC-Action")
        request.setValue(version, forHTTPHeaderField: "X-TC-Version")
        request.setValue("\(timestamp)", forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(config.region, forHTTPHeaderField: "X-TC-Region")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(TencentASRError.invalidResponse))
                return
            }
            guard http.statusCode == 200, let data else {
                print("TencentASR: HTTP \(http.statusCode)")
                completion(.failure(TencentASRError.http(http.statusCode)))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
                if let apiError = decoded.response.error {
                    print("TencentASR: API \(apiError.code) \(apiError.message)")
                    completion(.failure(TencentASRError.api(code: apiError.code, message: apiError.message)))
                    return
                }
                let text = decoded.response.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.isEmpty {
                    completion(.failure(TencentASRError.invalidResponse))
                } else {
                    completion(.success(text))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private struct APIResponse: Decodable {
        let response: APIResult

        enum CodingKeys: String, CodingKey {
            case response = "Response"
        }
    }

    private struct APIResult: Decodable {
        let result: String?
        let error: APIError?

        enum CodingKeys: String, CodingKey {
            case result = "Result"
            case error = "Error"
        }
    }

    private struct APIError: Decodable {
        let code: String
        let message: String

        enum CodingKeys: String, CodingKey {
            case code = "Code"
            case message = "Message"
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    private static func hmacSHA256(key: Data, message: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: symmetricKey))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func dateString(_ timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}

enum PCM16WAV {
    static func make(from pcm: Data, sampleRate: Int = 16_000) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcm.count
        let riffSize = 36 + dataSize

        var wav = Data()
        wav.append(Data("RIFF".utf8))
        wav.appendLE(UInt32(riffSize))
        wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8))
        wav.appendLE(UInt32(16))
        wav.appendLE(UInt16(1))
        wav.appendLE(UInt16(channels))
        wav.appendLE(UInt32(sampleRate))
        wav.appendLE(UInt32(byteRate))
        wav.appendLE(UInt16(blockAlign))
        wav.appendLE(UInt16(bitsPerSample))
        wav.append(Data("data".utf8))
        wav.appendLE(UInt32(dataSize))
        wav.append(pcm)
        return wav
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
