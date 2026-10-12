import Foundation

// TMAP's yyyyMMddHHmm request time is in Korea Standard Time.
// Convert the device's current instant once when the user requests a route.
struct DeliveryDepartureTime: Equatable {
    let planDate: String
    let startMinute: Int

    static func current(at date: Date = Date()) -> DeliveryDepartureTime {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return DeliveryDepartureTime(
            planDate: String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!),
            startMinute: parts.hour! * 60 + parts.minute!)
    }
}
