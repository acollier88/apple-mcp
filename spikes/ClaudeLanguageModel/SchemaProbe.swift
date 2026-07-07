// Probe: is GenerationSchema's Codable encoding JSON Schema?
// Run: swiftc -target arm64-apple-macos27.0 SchemaProbe.swift -o /tmp/schemaprobe && /tmp/schemaprobe

import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct WeatherArgs {
    @Guide(description: "City name, e.g. Austin")
    var city: String
    var celsius: Bool
    @Guide(description: "Days of forecast", .range(1...7))
    var days: Int
}

if #available(macOS 26.0, *) {
    let schema = WeatherArgs.generationSchema
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(schema)
    print(String(data: data, encoding: .utf8)!)
} else {
    print("needs macOS 26+")
}
