import Foundation
import AppKit
import WebKit
struct TMapCoordinate: Codable, Equatable {var longitude:Double;var latitude:Double;var poiID:String?;var detailAddress:String?}
enum PlannerFailure:LocalizedError {case message(String);var errorDescription:String?{if case .message(let s)=self{return s};return nil}}
@main struct FacilityLiveChecks {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory);app.finishLaunching()
        Task { await run() };app.run()
    }
    @MainActor static func run() async {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:393,height:700),styleMask:[.borderless],backing:.buffered,defer:false)
        let host=NSView(frame:NSRect(x:0,y:0,width:393,height:700));host.autoresizesSubviews=false;window.contentView=host;window.orderFront(nil)
        let a=RouteEndpoint(id:"public-seoul-station",name:"출발",address:"서울역",coordinate:TMapCoordinate(longitude:126.9707,latitude:37.5548))
        let b=RouteEndpoint(id:"public-cityhall",name:"도착",address:"서울시청",coordinate:TMapCoordinate(longitude:126.9779,latitude:37.5663))
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Asia/Seoul")!
        let date=calendar.date(bySettingHour:8,minute:0,second:0,of:Date().addingTimeInterval(7*86400))!
        var cases:[[String:Any]]=[]
        for provider in [FacilityRouteProvider.naverWeb,.kakaoWeb] {
            for mode in [FacilityTransport.walk,.transit,.car] {
                let runner=FacilityRouteWebRunner(), width=mode == .car ? 1280.0 : 320.0
                let request=FacilityRouteRequest(provider:provider,transport:mode,criterion:mode == .car ? .distance : .recommended,origin:a,destination:b,departure:mode == .car ? date : nil)
                let pending=Task {try await runner.query(request)}
                for _ in 0..<50 {if runner.webView != nil {break};await Task.yield()}
                if let view=runner.webView {view.autoresizingMask=[];view.frame=CGRect(x:0,y:0,width:width,height:700);host.addSubview(view)}
                do {
                    let rows=try await pending.value
                    guard !rows.isEmpty,rows.allSatisfy({$0.durationSeconds != nil && $0.provider == provider.rawValue && (mode != .car || $0.departureTime == KakaoRouteAPI.departure(date) && $0.timeBasis == "scheduled")}) else {throw PlannerFailure.message("unverified result")}
                    let item:[String:Any]=["provider":provider.rawValue,"mode":mode.rawValue,"viewportWidth":width,"passed":true,"rows":rows.count,"distanceMeters":rows.first!.distanceMeters as Any? ?? NSNull(),"durationSeconds":rows.first!.durationSeconds!,"timeBasis":rows.first!.timeBasis ?? "", "departure":rows.first!.departureTime ?? "", "url":rows.first!.landingURL ?? "", "summary":rows.first!.rawSummary ?? ""]
                    cases.append(item);print("LIVE_ROUTE_PASS \(provider.rawValue) \(mode.rawValue) \(rows.count) rows")
                } catch {cases.append(["provider":provider.rawValue,"mode":mode.rawValue,"viewportWidth":width,"passed":false,"error":error.localizedDescription,"lastMessage":runner.message,"url":runner.webView?.url?.absoluteString ?? ""]);print("LIVE_ROUTE_FAIL \(provider.rawValue) \(mode.rawValue): \(error.localizedDescription) / \(runner.message)")}
                runner.webView?.removeFromSuperview()
            }
        }
        let passed=cases.filter{$0["passed"] as? Bool == true}.count
        let report:[String:Any]=["checkedAt":ISO8601DateFormatter().string(from:Date()),"passed":passed,"total":cases.count,"device":"macOS native WKWebView, phone/mobile UA and desktop canvas","physicalIPhoneTested":false,"cases":cases]
        do {let data=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]);try data.write(to:URL(fileURLWithPath:"build/logs/facility-live.json"))} catch {print(error);exit(1)}
        print("NATIVE_FACILITY_LIVE_CHECKS \(passed)/\(cases.count)");exit(passed==cases.count ? 0 : 1)
    }
}
