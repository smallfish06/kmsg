import Foundation

private struct ErrorJSONResponse: Codable {
    let ok: Bool
    let error: String
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    if let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}

func printError(_ error: Error) throws {
    try printJSON(ErrorJSONResponse(ok: false, error: String(describing: error)))
}
