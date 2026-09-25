import Foundation

enum TokenroomFormat {
    static func percentText(_ value: Double) -> String {
        String(Int(max(0, min(100, value)).rounded()))
    }
}
