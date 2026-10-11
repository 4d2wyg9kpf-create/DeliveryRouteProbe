"""Read public provider documentation without credentials or API calls."""
import json
import re
import subprocess
import urllib.request
from pathlib import Path

OUT = Path('build/public-data-docs')
OUT.mkdir(parents=True, exist_ok=True)
URLS = {
    'bakery': 'https://www.data.go.kr/data/15155252/openapi.do',
    'download-helper': 'https://www.data.go.kr/js/biz/datset/script_fileDetail.js',
    'bakery-alt': 'https://data.go.kr/data/15155252/openapi.do',
    'kapt-api': 'https://www.data.go.kr/data/15058453/openapi.do',
    'kapt-list-api': 'https://www.data.go.kr/data/15057332/openapi.do',
    'kapt-basic-page': 'https://www.k-apt.go.kr/kaptinfo/openKaptInfo.do?aptCode=A30279105',
    'kapt-facility-page': 'https://www.k-apt.go.kr/kaptinfo/openKaptMng.do?aptCode=A30279105',
    'juso-search-doc': 'https://business.juso.go.kr/addrlink/openApi/searchApi.do',
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
        match = re.search(r'const swaggerJson = `(.*?)`;', content, re.S)
        if match:
            parser = OUT / (name + '.cjs')
            parser.write_text('process.stdout.write(JSON.stringify(JSON.parse(`' + match[1] + '`)));')
            encoded = subprocess.check_output(['node', str(parser)])
            (OUT / (name + '.swagger.json')).write_bytes(encoded)
            spec = json.loads(encoded)
            print(json.dumps({'host': spec.get('host'), 'paths': list(spec.get('paths', {}))}))
            for path, operations in spec.get('paths', {}).items():
                if path in ['/info', '/history', '/storeListInRadius']:
                    print(json.dumps({'path': path, 'parameters': operations.get('parameters', operations.get('get', {}).get('parameters')), 'description': operations.get('get', {}).get('description')}, ensure_ascii=False))
        for match in list(re.finditer(r'function fn_fileDownload|fileDownload\(|FILE_000|제과점', content))[:8]:
            print(content[max(0, match.start() - 100):match.end() + 800].replace('\n', ' '))
        if name.startswith(('kapt-', 'juso-')):
            for match in list(re.finditer(r'getApt|kaptd|aptCode|codePump|충전|addInfoYn|hemdNm|detBdNmList|ajax\(|url\s*:', content))[:35]:
                print(content[max(0, match.start() - 100):match.end() + 500].replace('\n', ' '))
            from urllib.parse import urljoin, urlsplit
            scripts = re.findall(r'<script[^>]+src=[\"\']([^\"\']+)', content)
            for i, src in enumerate(scripts):
                script_url = urljoin(url, src)
                if urlsplit(script_url).hostname not in ('www.k-apt.go.kr', 'business.juso.go.kr') or any(word in src.lower() for word in ('jquery', 'bootstrap', 'highchart', 'slick')):
                    continue
                try:
                    with urllib.request.urlopen(urllib.request.Request(script_url, headers={'User-Agent': 'Mozilla/5.0'}), timeout=15) as response:
                        script = response.read(3_000_001)
                    if len(script) > 3_000_000:
                        continue
                    (OUT / (name + '-script-' + str(i) + '.js')).write_bytes(script)
                    print(json.dumps({'script': script_url, 'bytes': len(script)}))
                except Exception as e:
                    print(json.dumps({'script': src, 'error': str(e)}))
    except Exception as error:
        print(json.dumps({'document': name, 'error': str(error)}, ensure_ascii=False))
