import Foundation

public enum LightCodec {
    public static func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return nil }
        return data.base64EncodedString()
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ base64: String) -> T? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}
