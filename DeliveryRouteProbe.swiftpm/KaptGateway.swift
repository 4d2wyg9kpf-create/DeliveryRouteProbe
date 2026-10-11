import Foundation

enum KaptRequest {
    case list, basic, facilities
    var service: PublicDataService { self == .list ? .kaptList : .kaptBasis }
    var path: String {
        switch self {
        case .list: return "/1613000/AptListService4/getLegaldongAptList4"
        case .basic: return "/1613000/AptBasisInfoServiceV5/getAphusBassInfoV5"
        case .facilities: return "/1613000/AptBasisInfoServiceV5/getAphusDtlInfoV5"
        }
    }
}
enum KaptGateway {
    static func request(_ action: KaptRequest, key: String, parameters: [String: String]) throws -> URLRequest {
        guard !key.isEmpty else { throw PlannerFailure.message("공공데이터 인증키와 K-apt API 활용승인을 먼저 설정하세요.") }
        var values = parameters
        if action == .list {
            guard values["bjdCode"]?.range(of: #"^\d{10}$"#, options: .regularExpression) != nil, let page = Int(values["pageNo"] ?? ""), (1...100_000).contains(page) else { throw DeviceShareError.invalid }
            values["numOfRows"] = "100"
        } else {
            guard values["kaptCode"]?.range(of: #"^[A-Za-z0-9]{1,40}$"#, options: .regularExpression) != nil else { throw DeviceShareError.invalid }
        }
        values[action == .facilities ? "ServiceKey" : "serviceKey"] = key
        var url = URLComponents(); url.scheme = "https"; url.host = "apis.data.go.kr"; url.path = action.path
        url.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B")
        guard let target = url.url else { throw DeviceShareError.invalid }; return URLRequest(url: target, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
    }
    static func text(_ row: [String: Any], _ key: String) -> String { PublicDataParser.string(row,key) }
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 8_000_000 else { throw DeviceShareError.invalid }
        if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return result }
        let parser = XMLParser(data: data), delegate = HousingXMLReader(); parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let result = delegate.result else { throw PlannerFailure.message("K-apt 응답 형식이 달라졌습니다.") }; return result
    }
    static func body(_ data: Data) throws -> [String: Any] {
        let root = try object(data), response = root["response"] as? [String: Any] ?? root["OpenAPI_ServiceResponse"] as? [String:Any] ?? root
        let header = response["header"] as? [String: Any] ?? response["cmmMsgHeader"] as? [String: Any] ?? [:]
        let code = text(header, "resultCode").isEmpty ? text(header, "returnReasonCode") : text(header, "resultCode")
        guard ["0", "00", "0000"].contains(code) else {
            if code.range(of: #"^-?\d{1,4}$"#, options: .regularExpression) != nil { throw PublicDataFailure.provider(code) }
            throw PlannerFailure.message("K-apt 결과코드를 확인하지 못했습니다. 활용승인·응답을 확인하세요.")
        }
        guard let body = response["body"] as? [String: Any] else { throw DeviceShareError.invalid }; return body
    }
}

// The gateway may return XML despite the portal's JSON label. Reject external
// entities and preserve repeated item elements as arrays.
private final class HousingXMLReader: NSObject, XMLParserDelegate {
    private struct Node { var name: String; var text = ""; var children: [String: Any] = [:] }
    private var stack: [Node] = []
    var result: [String: Any]?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) { stack.append(Node(name: elementName)) }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !stack.isEmpty { stack[stack.count-1].text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let node = stack.popLast() else { return }
        let value: Any = node.children.isEmpty ? node.text.trimmingCharacters(in:.whitespacesAndNewlines) : node.children
        if stack.isEmpty { result = [node.name:value] }
        else if let existing = stack[stack.count-1].children[node.name] {
            var array = existing as? [Any] ?? [existing]; array.append(value); stack[stack.count-1].children[node.name] = array
        } else { stack[stack.count-1].children[node.name] = value }
    }
}
