"""Read public provider documentation without credentials or API calls."""
import json
import re
import urllib.request
from pathlib import Path

OUT = Path('build/public-data-docs')
OUT.mkdir(parents=True, exist_ok=True)
URLS = {
    'restaurants': 'https://www.data.go.kr/data/15154916/openapi.do',
    'cafes': 'https://www.data.go.kr/data/15154921/openapi.do',
    'catering': 'https://www.data.go.kr/data/15155159/openapi.do',
    'canteens': 'https://www.data.go.kr/data/15155168/openapi.do',
    'stores': 'https://www.data.go.kr/data/15012005/openapi.do',
    'bakery-index': 'https://data.edmgr.kr/dataView.do?id=www-data-go-kr-data-filedata-15044973',
    'manual': 'https://www.localdata.go.kr/images/egovframework/portal/manual_260106.pdf',
}
for name, url in URLS.items():
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=25) as response:
            data = response.read(15_000_001)
        if len(data) > 15_000_000:
            raise ValueError('Documentation size limit exceeded')
        (OUT / (name + ('.pdf' if name == 'manual' else '.html'))).write_bytes(data)
        print(json.dumps({'document': name, 'bytes': len(data)}, ensure_ascii=False))
        if name == 'manual':
            continue
        content = data.decode('utf-8', errors='replace')
        for match in list(re.finditer(r'swagger|apiDoc|apis\.data|fileDownload|openapi\.do|[A-Za-z]+\.json', content, re.I))[:45]:
            print(content[max(0, match.start() - 160):match.end() + 420].replace('\n', ' '))
    except Exception as error:
        print(json.dumps({'document': name, 'error': str(error)}, ensure_ascii=False))
