import Foundation

// One row in the in-app activity log. Plain Codable value type; persisted as
// part of the LogStore's JSON array. `category` drives the row icon/chip in the
// UI, `level` the severity colouring.
public struct LogEntry: Identifiable, Codable, Sendable, Equatable {
    public enum Level: String, Codable, Sendable {
        case info, warning, error
    }

    public enum Category: String, Codable, Sendable {
        case job, recording
    }

    public let id: UUID
    public let date: Date
    public let level: Level
    public let category: Category
    public let message: String

    public init(
        id: UUID = UUID(),
        date: Date,
        level: Level,
        category: Category,
        message: String
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}
