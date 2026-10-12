import Foundation

@main struct DepartureTimeChecks {
    static func main() throws {
        let formatter = ISO8601DateFormatter()
        var checks: [[String: Any]] = []
        func check(_ name: String, _ instant: String, _ day: String, _ minute: Int) throws {
            let value = DeliveryDepartureTime.current(at: formatter.date(from: instant)!)
            guard value.planDate == day, value.startMinute == minute else {
                throw NSError(domain: "DepartureTimeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
            }
            checks.append(["name": name, "passed": true])
        }
        try check("Request uses the device instant in KST", "2026-10-12T00:59:11Z", "2026-10-12", 599)
        try check("Last minute before Korean midnight stays on its date", "2026-10-11T14:59:59Z", "2026-10-11", 1439)
        try check("Korean midnight updates both date and time", "2026-10-11T15:00:00Z", "2026-10-12", 0)
        try check("New Year updates the route date", "2026-12-31T15:00:00Z", "2027-01-01", 0)
        try check("Leap-day rollover uses the Gregorian calendar", "2028-02-28T15:00:00Z", "2028-02-29", 0)
        try check("A later request obtains a fresh minute", "2026-10-12T01:00:00Z", "2026-10-12", 600)
        let previousZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = previousZone }
        try check("Device timezone changes cannot shift the TMAP KST request", "2026-10-12T00:59:11Z", "2026-10-12", 599)
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": checks.count, "total": checks.count, "checks": checks], options: [.sortedKeys]), as: UTF8.self))
    }
}
