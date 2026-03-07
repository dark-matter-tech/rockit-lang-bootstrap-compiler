// Capability.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

// MARK: - Capability Status

/// The grant status of a platform capability.
public enum CapabilityStatus: Equatable, CustomStringConvertible {
    /// Capability has been granted.
    case granted
    /// Capability has been denied.
    case denied
    /// Capability status is unknown (not yet requested).
    case unknown

    public var description: String {
        switch self {
        case .granted: return "granted"
        case .denied:  return "denied"
        case .unknown: return "unknown"
        }
    }
}

// MARK: - Capability Descriptor

/// Describes a platform capability that a Rockit program may request.
public struct CapabilityDescriptor: CustomStringConvertible {
    /// The capability name (e.g., "Network", "FileSystem", "Camera").
    public let name: String

    /// Human-readable description of what the capability allows.
    public let summary: String

    /// Current status.
    public var status: CapabilityStatus

    public init(name: String, summary: String, status: CapabilityStatus = .unknown) {
        self.name = name
        self.summary = summary
        self.status = status
    }

    public var description: String {
        "Capability(\(name): \(status))"
    }
}

// MARK: - Capability Registry

/// Registry for platform capabilities.
///
/// In the Rockit runtime, capabilities are explicit declarations that
/// must be granted before a program can access platform features.
/// This provides a security sandbox model similar to mobile app permissions.
///
/// Stage 0 pre-registers standard capabilities as stubs. The actual
/// platform integration happens in later stages when Rockit runs natively.
public final class CapabilityRegistry {
    /// All registered capabilities.
    private var capabilities: [String: CapabilityDescriptor] = [:]

    /// Callback invoked when a capability is requested.
    /// In Stage 0, this defaults to auto-granting for testing.
    public var requestHandler: ((String) -> CapabilityStatus)?

    public init() {
        registerDefaults()
    }

    // MARK: - Registration

    /// Register a capability descriptor.
    public func register(_ descriptor: CapabilityDescriptor) {
        capabilities[descriptor.name] = descriptor
    }

    /// Register default platform capabilities (stubs for Stage 0).
    private func registerDefaults() {
        let defaults: [(String, String)] = [
            ("Network", "Access to network requests (HTTP, WebSocket)"),
            ("FileSystem", "Read/write access to the file system"),
            ("Camera", "Access to device camera"),
            ("Microphone", "Access to device microphone"),
            ("Location", "Access to device location services"),
            ("Notifications", "Push and local notifications"),
            ("Clipboard", "Read/write system clipboard"),
            ("Storage", "Persistent local storage"),
            ("Sensors", "Access to device sensors (accelerometer, gyroscope)"),
            ("Bluetooth", "Bluetooth connectivity"),
        ]
        for (name, summary) in defaults {
            capabilities[name] = CapabilityDescriptor(name: name, summary: summary)
        }
    }

    // MARK: - Queries

    /// Check if a capability is granted.
    public func check(_ name: String) -> Bool {
        capabilities[name]?.status == .granted
    }

    /// Get the status of a capability.
    public func status(of name: String) -> CapabilityStatus {
        capabilities[name]?.status ?? .unknown
    }

    /// Get a capability descriptor by name.
    public func descriptor(for name: String) -> CapabilityDescriptor? {
        capabilities[name]
    }

    /// All registered capability names.
    public var allCapabilities: [String] {
        capabilities.keys.sorted()
    }

    // MARK: - Grant/Deny

    /// Grant a capability.
    public func grant(_ name: String) {
        capabilities[name]?.status = .granted
    }

    /// Deny a capability.
    public func deny(_ name: String) {
        capabilities[name]?.status = .denied
    }

    /// Request a capability. Uses the requestHandler if set,
    /// otherwise auto-grants in Stage 0.
    public func request(_ name: String) -> CapabilityStatus {
        if let handler = requestHandler {
            let result = handler(name)
            capabilities[name]?.status = result
            return result
        }
        // Stage 0 default: auto-grant
        capabilities[name]?.status = .granted
        return .granted
    }

    /// Require a capability. Throws if not granted.
    public func require(_ name: String) throws {
        let status = self.status(of: name)
        switch status {
        case .granted:
            return
        case .denied:
            throw VMError.capabilityDenied(name: name)
        case .unknown:
            let result = request(name)
            if result != .granted {
                throw VMError.capabilityDenied(name: name)
            }
        }
    }

    // MARK: - Statistics

    public var statsDescription: String {
        let granted = capabilities.values.filter { $0.status == .granted }.count
        let denied = capabilities.values.filter { $0.status == .denied }.count
        let unknown = capabilities.values.filter { $0.status == .unknown }.count
        return """
        --- Capability Registry ---
          Total capabilities: \(capabilities.count)
          Granted:            \(granted)
          Denied:             \(denied)
          Unknown:            \(unknown)
        --- End Capabilities ---
        """
    }
}
