import Foundation
import AppKit
import WebKit

struct TMapCoordinate: Codable, Equatable { var longitude: Double; var latitude: Double; var poiID: String?; var detailAddress: String? }
enum PlannerFailure: LocalizedError { case message(String); var errorDescription: String? { if case .message(let text) = self { return text }; return nil } }

@MainActor final class FacilityChecks: NSObject {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 393, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    var view = WKWebView(frame: CGRect(x: 0, y: 0, width: 393, height: 700))
    var count = 0
    let origin = RouteEndpoint(id: "a", name: "출발", address: "서울역", coordinate: TMapCoordinate(longitude: 126.9707, latitude: 37.5548))
    let destination = RouteEndpoint(id: "b", name: "도착", address: "서울시청", coordinate: TMapCoordinate(longitude: 126.9779, latitude: 37.5663))
    func check(_ value: Bool, _ name: String) throws { guard value else { throw PlannerFailure.message(name) };count += 1;print("PASS \(name)") }
    func rejects(_ name: String, _ action: () throws -> Void) throws { do { try action() } catch { try check(true,name);return };throw PlannerFailure.message(name) }
    var fixtureSource: String {
        FacilityRouteWebScript.source.replacingOccurrences(of: "'https:'", with: "'http:'")
            .replacingOccurrences(of: "'map.naver.com'", with: "'127.0.0.1'")
            .replacingOccurrences(of: "'m.map.naver.com'", with: "'127.0.0.1'")
            .replacingOccurrences(of: "'m.search.naver.com'", with: "'127.0.0.1'")
            .replacingOccurrences(of: "'map.kakao.com'", with: "'127.0.0.1'")
            .replacingOccurrences(of: "'m.map.kakao.com'", with: "'127.0.0.1'")
    }
    func evaluate(_ body: String, args: [String: Any] = [:]) async throws -> [String: Any] {
        let raw: Any = try await withCheckedThrowingContinuation { c in view.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { c.resume(with: $0) } }
        guard let s = raw as? String, let data = s.data(using: .utf8), let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PlannerFailure.message("fixture JSON") }; return result
    }
    func load(_ url: URL, width: Double) async throws {
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 700));window.contentView = view;window.orderFront(nil)
        view.load(URLRequest(url: url))
        for _ in 0..<50 {
            if let value = try? await evaluate("return JSON.stringify({ready:document.readyState==='complete'&&!!document.querySelector('section,main,#section_content')});"), value["ready"] as? Bool == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        };throw PlannerFailure.message("fixture did not load")
    }
    func reply(_ request: FacilityRouteRequest, attempts: Int = 50) async throws -> [String: Any] {
        var value: [String: Any] = [:]
        for _ in 0..<attempts {
            value = try await evaluate(fixtureSource + "\nreturn JSON.stringify(DeliveryFacilityWeb.step(request));", args: ["request":request.scriptArguments])
            if value["status"] as? String != "pending" { return value }
            try await Task.sleep(nanoseconds: 400_000_000)
        };return value
    }
    func mobileURL(_ request: FacilityRouteRequest, fixture: String) -> URL {
        let o = request.origin.coordinate, d = request.destination.coordinate
        var url = URLComponents(string: "http://127.0.0.1:8392/search.naver")!
        let value = "placeType^place;name^출발;longitude^\(o.longitude);latitude^\(o.latitude)|type^place;name^도착;longitude^\(d.longitude);latitude^\(d.latitude)|objtype^path;by^\(request.transport == .walk ? "walking" : "pubtrans")"
        url.queryItems = [URLQueryItem(name: "nso_path", value: value), URLQueryItem(name: "fixture",value:fixture)];return url.url!
    }
    func run() async {
        do {
            for width in [320.0,393.0,1280.0] {
                let r = FacilityRouteRequest(provider:.naverWeb,transport:.walk,criterion:.recommended,origin:origin,destination:destination)
                try await load(mobileURL(r,fixture:width==320 ? "outside" : "walk"),width:width)
                let first = try await evaluate(fixtureSource + "\nreturn JSON.stringify(DeliveryFacilityWeb.step(request));",args:["request":r.scriptArguments])
                try check(first["status"] as? String == "pending", "\(width)px result is not saved before stable readings")
                let result = try await reply(r), rows = result["candidates"] as? [[String: Any]] ?? []
                try check(result["status"] as? String == "ready" && rows.count == 2, "\(width)px reads rendered summaries, including cropped desktop area")
                try check(rows.first?["durationSeconds"] as? Int == 3780 && rows.first?["distanceMeters"] as? Int == 3700, "\(width)px units exclude scale steps and money")
                var wrong=r;wrong.destination.coordinate.longitude += 0.001
                try check(try await reply(wrong)["status"] as? String == "error", "\(width)px edited destination rejects previous DOM")
            }
            let transit = FacilityRouteRequest(provider:.naverWeb,transport:.transit,criterion:.recommended,origin:origin,destination:destination)
            try await load(mobileURL(transit,fixture:"transit"),width:320)
            let pt = try await reply(transit), ptRows = pt["candidates"] as? [[String: Any]] ?? []
            try check(ptRows.count == 2 && ptRows.first?["durationSeconds"] as? Int == 2700 && ptRows.first?["distanceMeters"] is NSNull, "NAVER transit captures total time, never bus numbers or leg durations")
            let hidden = FacilityRouteRequest(provider:.naverWeb,transport:.walk,criterion:.recommended,origin:origin,destination:destination)
            try await load(mobileURL(hidden,fixture:"hidden"),width:320)
            try check(try await reply(hidden,attempts:4)["status"] as? String == "pending", "hidden old results cannot be saved")
            for mode in [FacilityTransport.walk,.transit] {
                let r=FacilityRouteRequest(provider:.kakaoWeb,transport:mode,criterion:.recommended,origin:origin,destination:destination)
                let path=mode == .walk ? "walkRoute" : "publicRoute"
                var url=URLComponents(string:"http://127.0.0.1:8392/actions/\(path)")!
                url.queryItems=[URLQueryItem(name:"startLoc",value:"출발"),URLQueryItem(name:"endLoc",value:"도착")]+["sxEnc","syEnc","exEnc","eyEnc"].enumerated().map { URLQueryItem(name:$0.element,value:["A","B","C","D"][$0.offset]) }
                try await load(url.url!,width:320)
                let result=try await reply(r),rows=result["candidates"] as? [[String:Any]] ?? []
                try check(result["status"] as? String == "ready" && rows.first?["durationSeconds"] as? Int == (mode == .walk ? 5340 : 780),"Kakao mobile \(mode.rawValue) at 320px captures only total time")
            }
            let date=ISO8601DateFormatter().date(from:"2026-11-01T23:00:00Z")!
            let future=FacilityRouteRequest(provider:.naverWeb,transport:.car,criterion:.distance,origin:origin,destination:destination,departure:date)
            var pc=URLComponents(url:future.webURL,resolvingAgainstBaseURL:false)!;pc.scheme="http";pc.host="127.0.0.1";pc.port=8392;pc.queryItems=[URLQueryItem(name:"fixture",value:"future")]
            try await load(pc.url!,width:1280)
            let prediction=try await reply(future,attempts:90),predRows=prediction["candidates"] as? [[String:Any]] ?? []
            try check(prediction["status"] as? String == "ready" && prediction["departureKey"] as? String == "202611020800", "desktop NAVER selects year month day AM hour minute before accepting prediction")
            try check(predRows.first?["durationSeconds"] as? Int == 1080 && predRows.first?["distanceMeters"] is NSNull && predRows.first?["referenceDistanceMeters"] as? Int == 2500, "future total uses prediction, keeps current distance separate")
            let decode=try JSONDecoder().decode(FacilityWebReply.self,from:JSONSerialization.data(withJSONObject:["status":"ready","requestID":future.id,"pageURL":future.webURL.absoluteString,"timeBasis":"scheduled","departureKey":"202611020800","candidates":predRows]))
            let saved=try FacilityRouteRecords.web(decode,request:future)
            try check(saved[0].distanceMeters == nil && saved[0].referenceDistanceMeters == 2500 && saved[0].provider == "naverWeb", "prediction provenance and optional distance survive record conversion")
            var wrong=decode;wrong.departureKey="202611020810"
            try rejects("mismatched departure may not fall back to current time") { _=try FacilityRouteRecords.web(wrong,request:future) }
            wrong=decode;wrong.requestID="previous"
            try rejects("previous request nonce cannot become current route") { _=try FacilityRouteRecords.web(wrong,request:future) }
            var apiRequest=future;apiRequest.provider = .naverAPI;apiRequest.departure=nil;apiRequest.criterion = .time
            let summary:[String:Any]=["distance":1234,"duration":90001,"start":["location":[origin.coordinate.longitude,origin.coordinate.latitude]],"goal":["location":[destination.coordinate.longitude,destination.coordinate.latitude]]]
            let apiRows=try FacilityRouteRecords.naver(["code":0,"route":["trafast":[["summary":summary]]]],request:apiRequest)
            try check(apiRows[0].durationSeconds == 91 && apiRows[0].distanceMeters == 1234, "Directions 5 milliseconds convert to seconds without truncating")
            var wrongSummary=summary;wrongSummary["goal"]=["location":[127.0,37.5]]
            try rejects("wrong API endpoint coordinates reject route") { _=try FacilityRouteRecords.naver(["code":0,"route":["trafast":[["summary":wrongSummary]]]],request:apiRequest) }
            var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(apiRows[0])) as! [String:Any];for key in ["provider","timeBasis","rawSummary","referenceDistanceMeters"] {json.removeValue(forKey:key)}
            let old=try JSONDecoder().decode(KakaoDistanceRecord.self,from:JSONSerialization.data(withJSONObject:json))
            try check(old.provider == nil && old.distanceMeters == 1234, "previous version records decode without new metadata")
            let runner=FacilityRouteWebRunner(), cancelled=Task { try await runner.query(hidden) };cancelled.cancel()
            do { _=try await cancelled.value;throw PlannerFailure.message("cancel expected") } catch is CancellationError {try check(runner.webView == nil,"cancel before query prevents navigation")}
            print("NATIVE_FACILITY_ROUTE_CHECKS \(count)/\(count)");exit(0)
        } catch {print("FAIL facility route checks: \(error)");exit(1)}
    }
}
@main struct FacilityRouteTests { @MainActor static func main() {let app=NSApplication.shared;app.setActivationPolicy(.accessory);app.finishLaunching();let checks=FacilityChecks();Task{await checks.run()};app.run()} }
