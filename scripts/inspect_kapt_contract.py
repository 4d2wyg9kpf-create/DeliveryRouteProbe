"""Compare the shipped K-apt requests with public portal documentation.

This does not use an API key or make authenticated data requests. A matching
contract does not demonstrate that the upstream provider is serving data.
"""
import json
import re
import urllib.request
from pathlib import Path


CONTRACTS = [
    {
        "name": "K-apt list",
        "documentation": "https://www.data.go.kr/data/15057332/openapi.do",
        "host": "apis.data.go.kr/1613000/AptListService4",
        "operations": {"/getTotalAptList4": ["serviceKey", "pageNo", "numOfRows"]},
    },
    {
        "name": "K-apt basic and facilities",
        "documentation": "https://www.data.go.kr/data/15058453/openapi.do",
        "host": "apis.data.go.kr/1613000/AptBasisInfoServiceV5",
        "operations": {
            "/getAphusBassInfoV5": ["serviceKey", "kaptCode"],
            "/getAphusDtlInfoV5": ["ServiceKey", "kaptCode"],
        },
    },
]


def inspect(contract):
    result = {"name": contract["name"], "documentation": contract["documentation"]}
    try:
        request = urllib.request.Request(contract["documentation"], headers={"User-Agent": "DeliveryRouteProbe-contract-check/0.24.1"})
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read(2_000_001)
        if len(raw) > 2_000_000:
            raise ValueError("documentation exceeded size limit")
        match = re.search(r"const swaggerJson = `(.*?)`;", raw.decode("utf-8"), re.S)
        if match is None:
            raise ValueError("public documentation did not contain the inline specification")
        spec = json.loads(match[1])
        result["host"] = spec.get("host")
        result["schemes"] = spec.get("schemes", [])
        result["operations"] = []
        matches = result["host"] == contract["host"] and "https" in result["schemes"]
        for path, expected in contract["operations"].items():
            operation = spec.get("paths", {}).get(path, {})
            get = operation.get("get")
            names = [p.get("name") for p in (get or {}).get("parameters", operation.get("parameters", []))]
            valid = get is not None and set(expected).issubset(names)
            matches = matches and valid
            result["operations"].append({"path": path, "query_parameters": names, "matches_shipped_request": valid})
        result["status"] = "contract_matches" if matches else "contract_mismatch"
    except Exception as error:
        result["status"] = "unverified"
        result["reason"] = type(error).__name__ + ": " + str(error)
    return result


if __name__ == "__main__":
    results = [inspect(contract) for contract in CONTRACTS]
    report = {"authenticated_data_test": "not_performed", "results": results}
    output = Path("build/logs/kapt-contract.json")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))
    raise SystemExit(0 if all(r["status"] == "contract_matches" for r in results) else 1)
