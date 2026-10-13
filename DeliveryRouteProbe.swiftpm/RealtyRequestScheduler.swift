import Foundation

struct RealtyCollectionInterruption: LocalizedError {
    let reason: String
    var resumeAt: Date? = nil
    var errorDescription: String? { reason }
}

struct RealtyRequestPolicy {
    // One in-flight request across every client, with no per-apartment burst.
    let minimumInterval: TimeInterval
    init(minimumInterval: TimeInterval = 0.35) { self.minimumInterval = max(0, minimumInterval) }
    static func retryAfter(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        if let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return f.date(from: value).map { max(now, $0) }
    }
    func retryDate(status: Int, attempt: Int, header: String?, now: Date) -> Date {
        let base: TimeInterval = status == 429 ? 30 : 5
        return max(Self.retryAfter(header, now: now) ?? now, now.addingTimeInterval(base * pow(2, Double(attempt))))
    }
}

actor RealtyRequestScheduler {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    static let shared = RealtyRequestScheduler(persistCooldown: true)
    private let policy: RealtyRequestPolicy
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private let persistCooldown: Bool
    private var busy = false
    private var nextStart = Date.distantPast
    private var blockedUntil = Date.distantPast
    init(policy: RealtyRequestPolicy = RealtyRequestPolicy(), persistCooldown: Bool = false,
         now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 60)) * 1_000_000_000))
         }) {
        self.policy = policy; self.persistCooldown = persistCooldown; self.now = now; self.sleep = sleep
        if persistCooldown { blockedUntil = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "realty-collection-cooldown-until")) }
    }
    private func block(until date: Date) {
        blockedUntil = max(blockedUntil, date)
        if persistCooldown { UserDefaults.standard.set(blockedUntil.timeIntervalSince1970, forKey: "realty-collection-cooldown-until") }
    }
    private func wait(until date: Date) async throws {
        while now() < date { try Task.checkCancellation(); try await sleep(min(60, date.timeIntervalSince(now()))) }
        try Task.checkCancellation()
    }
    func data(for request: URLRequest, transport: Transport) async throws -> Data {
        while busy { try Task.checkCancellation(); try await sleep(0.05) }
        try Task.checkCancellation()
        guard now() >= blockedUntil else {
            throw RealtyCollectionInterruption(reason: "공시가격 서버의 요청 제한으로 수집을 보류했습니다. 대기 시간이 지난 뒤 이어서 수집하세요.", resumeAt: blockedUntil)
        }
        busy = true; defer { busy = false }
        for attempt in 0...2 {
            try await wait(until: nextStart)
            nextStart = now().addingTimeInterval(policy.minimumInterval)
            let data: Data, response: URLResponse
            do { (data, response) = try await transport(request) }
            catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch {
                guard attempt < 2 else { throw RealtyCollectionInterruption(reason: "네트워크 연결을 확인한 뒤 이어서 수집하세요. " + error.localizedDescription) }
                nextStart = now().addingTimeInterval(pow(2, Double(attempt + 1))); continue
            }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url?.host == "www.realtyprice.kr", data.count <= 50_000_000 else {
                throw RealtyCollectionInterruption(reason: "공시가격 응답의 출처와 크기를 확인하지 못해 수집을 보류했습니다.")
            }
            if http.statusCode == 403 || http.statusCode == 401 {
                let until = max(RealtyRequestPolicy.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: now()) ?? now(), now().addingTimeInterval(300))
                block(until: until)
                throw RealtyCollectionInterruption(reason: "공시가격 서버가 접근을 제한하여 수집을 보류했습니다.", resumeAt: until)
            }
            if [429, 500, 502, 503, 504].contains(http.statusCode) {
                let date = policy.retryDate(status: http.statusCode, attempt: attempt, header: http.value(forHTTPHeaderField: "Retry-After"), now: now())
                block(until: date)
                guard attempt < 2, date.timeIntervalSince(now()) <= 120 else {
                    throw RealtyCollectionInterruption(reason: "공시가격 서버가 혼잡하거나 요청을 제한하여 수집을 보류했습니다. 대기 후 이어서 수집하세요.", resumeAt: date)
                }
                nextStart = date; continue
            }
            guard http.statusCode == 200 else { throw PlannerFailure.message("공시가격 자료 응답 오류: HTTP \(http.statusCode)") }
            // A challenge page must stop the job instead of being retried for every apartment.
            let prefix = String(decoding: data.prefix(16_384), as: UTF8.self).lowercased()
            if prefix.contains("captcha") || prefix.contains("access denied") || prefix.contains("비정상적인 접근") || prefix.contains("접근이 제한") {
                let until = now().addingTimeInterval(300); block(until: until)
                throw RealtyCollectionInterruption(reason: "공시가격 서버의 접근 확인 화면이 나타나 수집을 보류했습니다.", resumeAt: until)
            }
            return data
        }
        throw RealtyCollectionInterruption(reason: "공시가격 수집을 보류했습니다.")
    }
}
