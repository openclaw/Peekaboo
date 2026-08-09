//
//  ToolResultExtractor.swift
//  PeekabooCore
//

import Foundation

/// Utility for extracting values from tool results with automatic unwrapping of nested structures
public enum ToolResultExtractor {
    // MARK: - String Extraction

    /// Extract a string value from the result, handling wrapped values automatically
    public static func string(_ key: String, from result: [String: Any]) -> String? {
        // Try direct access first
        if let value = result[key] as? String {
            return value
        }

        // Try wrapped format {"type": "object", "value": {...}}
        if let wrapper = result[key] as? [String: Any],
           let value = wrapper["value"] as? String
        {
            return value
        }

        // Try nested in data
        if let data = result["data"] as? [String: Any],
           let value = data[key] as? String
        {
            return value
        }

        // Try metadata
        if let metadata = result["metadata"] as? [String: Any],
           let value = metadata[key] as? String
        {
            return value
        }

        return nil
    }

    // MARK: - Integer Extraction

    /// Extract an integer value from the result
    public static func int(_ key: String, from result: [String: Any]) -> Int? {
        // Try direct Int
        if let value = result[key] as? Int {
            return value
        }

        // Try Double and convert
        if let value = result[key] as? Double {
            return Int(value)
        }

        // Try String and convert
        if let stringValue = string(key, from: result),
           let intValue = Int(stringValue)
        {
            return intValue
        }

        // Try wrapped format
        if let wrapper = result[key] as? [String: Any] {
            if let value = wrapper["value"] as? Int {
                return value
            }
            if let value = wrapper["value"] as? Double {
                return Int(value)
            }
            if let value = wrapper["value"] as? String,
               let intValue = Int(value)
            {
                return intValue
            }
        }

        // Try nested in data
        if let data = result["data"] as? [String: Any] {
            if let value = data[key] as? Int {
                return value
            }
            if let value = data[key] as? Double {
                return Int(value)
            }
        }

        return nil
    }

    // MARK: - Double Extraction

    /// Extract a Double value from the result
    public static func double(_ key: String, from result: [String: Any]) -> Double? {
        if let value = result[key] as? Double {
            return value
        }
        if let value = result[key] as? Int {
            return Double(value)
        }
        if let stringValue = string(key, from: result), let d = Double(stringValue) {
            return d
        }
        if let wrapper = result[key] as? [String: Any] {
            if let v = wrapper["value"] as? Double {
                return v
            }
            if let v = wrapper["value"] as? Int {
                return Double(v)
            }
            if let v = wrapper["value"] as? String, let d = Double(v) {
                return d
            }
        }
        if let data = result["data"] as? [String: Any] {
            if let v = data[key] as? Double {
                return v
            }
            if let v = data[key] as? Int {
                return Double(v)
            }
        }
        return nil
    }

    // MARK: - Boolean Extraction

    /// Extract a boolean value from the result
    public static func bool(_ key: String, from result: [String: Any]) -> Bool? {
        // Try direct Bool
        if let value = result[key] as? Bool {
            return value
        }

        // Try String representations
        if let stringValue = string(key, from: result) {
            switch stringValue.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                break
            }
        }

        // Try wrapped format
        if let wrapper = result[key] as? [String: Any],
           let value = wrapper["value"] as? Bool
        {
            return value
        }

        // Try nested in data
        if let data = result["data"] as? [String: Any],
           let value = data[key] as? Bool
        {
            return value
        }

        return nil
    }

    // MARK: - Array Extraction

    /// Extract an array from the result
    public static func array<T>(_ key: String, from result: [String: Any]) -> [T]? {
        // Try direct array
        if let value = result[key] as? [T] {
            return value
        }

        // Try wrapped format
        if let wrapper = result[key] as? [String: Any],
           let value = wrapper["value"] as? [T]
        {
            return value
        }

        // Try nested in data
        if let data = result["data"] as? [String: Any],
           let value = data[key] as? [T]
        {
            return value
        }

        return nil
    }

    // MARK: - Dictionary Extraction

    /// Extract a dictionary from the result
    public static func dictionary(_ key: String, from result: [String: Any]) -> [String: Any]? {
        // Try direct dictionary
        if let value = result[key] as? [String: Any] {
            // Check if it's a wrapped value
            if value["type"] as? String == "object",
               let actualValue = value["value"] as? [String: Any]
            {
                return actualValue
            }
            return value
        }

        // Try nested in data
        if let data = result["data"] as? [String: Any],
           let value = data[key] as? [String: Any]
        {
            return value
        }

        return nil
    }

    // MARK: - Coordinates Extraction

    /// Extract coordinates from the result (handles various formats)
    public static func coordinates(from result: [String: Any]) -> (x: Int, y: Int)? {
        // Try coords string format "x,y"
        if let coords = string("coords", from: result) {
            let components = coords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if components.count == 2,
               let x = Int(components[0]),
               let y = Int(components[1])
            {
                return (x, y)
            }
        }

        // Try separate x and y fields
        if let x = extractCoordinate("x", from: result),
           let y = extractCoordinate("y", from: result)
        {
            return (x, y)
        }

        return nil
    }

    private static func extractCoordinate(_ key: String, from result: [String: Any]) -> Int? {
        // Try direct access
        if let value = result[key] {
            if let intValue = value as? Int {
                return intValue
            }
            if let doubleValue = value as? Double {
                return Int(doubleValue)
            }
            if let stringValue = value as? String,
               let intValue = Int(stringValue)
            {
                return intValue
            }
            // Handle wrapped coordinate
            if let wrapper = value as? [String: Any],
               let wrappedValue = wrapper["value"]
            {
                if let intValue = wrappedValue as? Int {
                    return intValue
                }
                if let doubleValue = wrappedValue as? Double {
                    return Int(doubleValue)
                }
                if let stringValue = wrappedValue as? String,
                   let intValue = Int(stringValue)
                {
                    return intValue
                }
            }
        }
        return nil
    }

    // MARK: - Success Detection

    /// Check if the result indicates success
    public static func isSuccess(_ result: [String: Any]) -> Bool {
        // Check success field
        if let success = bool("success", from: result) {
            return success
        }

        // Check for error field
        if let error = string("error", from: result), !error.isEmpty {
            return false
        }

        // Check exit code for shell commands
        if let exitCode = int("exitCode", from: result) {
            return exitCode == 0
        }

        // Default to true if no explicit failure indicators
        return true
    }
}
