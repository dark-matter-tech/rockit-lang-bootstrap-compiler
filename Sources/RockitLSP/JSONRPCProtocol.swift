// JSONRPCProtocol.swift
// RockitLSP — Rockit Language Server Protocol
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import Foundation

// MARK: - Message Types

/// Identifier for a JSON-RPC request (int or string per spec)
public enum JSONRPCId: Equatable {
    case int(Int)
    case string(String)

    func toJSON() -> Any {
        switch self {
        case .int(let v): return v
        case .string(let v): return v
        }
    }

    init?(json: Any) {
        if let v = json as? Int {
            self = .int(v)
        } else if let v = json as? String {
            self = .string(v)
        } else {
            return nil
        }
    }
}

/// A parsed JSON-RPC 2.0 message (request or notification)
public struct JSONRPCMessage {
    public let id: JSONRPCId?
    public let method: String
    public let params: [String: Any]?
}

/// An error in a JSON-RPC response
public struct JSONRPCError {
    public let code: Int
    public let message: String

    func toJSON() -> [String: Any] {
        return ["code": code, "message": message]
    }
}

// MARK: - Protocol IO

/// Reads and writes JSON-RPC 2.0 messages with Content-Length framing
public final class JSONRPCProtocol {

    /// Read a single JSON-RPC message from the given file handle (blocking).
    /// Returns nil on EOF or invalid input.
    public static func readMessage(from input: FileHandle) -> JSONRPCMessage? {
        // Read headers until \r\n\r\n
        var headerData = Data()
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

        while true {
            let byte = input.readData(ofLength: 1)
            if byte.isEmpty { return nil } // EOF
            headerData.append(byte)

            if headerData.count >= 4 && headerData.suffix(4) == separator {
                break
            }

            // Safety: headers shouldn't be longer than 4KB
            if headerData.count > 4096 { return nil }
        }

        // Parse Content-Length from headers
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        var contentLength: Int? = nil
        for line in headerString.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }

        guard let length = contentLength, length > 0 else { return nil }

        // Read exactly `length` bytes of content
        var contentData = Data()
        while contentData.count < length {
            let remaining = length - contentData.count
            let chunk = input.readData(ofLength: remaining)
            if chunk.isEmpty { return nil } // EOF
            contentData.append(chunk)
        }

        // Parse JSON
        guard let json = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
            return nil
        }

        guard let method = json["method"] as? String else { return nil }

        let id: JSONRPCId?
        if let rawId = json["id"] {
            id = JSONRPCId(json: rawId)
        } else {
            id = nil
        }

        let params = json["params"] as? [String: Any]

        return JSONRPCMessage(id: id, method: method, params: params)
    }

    /// Write a JSON-RPC response (success or error) to the given file handle.
    public static func writeResponse(id: JSONRPCId, result: Any?, error: JSONRPCError?, to output: FileHandle) {
        var json: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.toJSON()
        ]

        if let error = error {
            json["error"] = error.toJSON()
        } else if let result = result {
            json["result"] = result
        } else {
            json["result"] = NSNull()
        }

        writeJSON(json, to: output)
    }

    /// Write a JSON-RPC notification (server → client, no id).
    public static func writeNotification(method: String, params: [String: Any], to output: FileHandle) {
        let json: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        writeJSON(json, to: output)
    }

    // MARK: - Internal

    private static func writeJSON(_ json: [String: Any], to output: FileHandle) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: []) else { return }
        let header = "Content-Length: \(data.count)\r\n\r\n"
        guard let headerData = header.data(using: .utf8) else { return }
        output.write(headerData)
        output.write(data)
    }
}
