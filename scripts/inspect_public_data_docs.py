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
    except Exception as error:
        print(json.dumps({'document': name, 'error': str(error)}, ensure_ascii=False))
