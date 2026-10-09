"""Local DOM fixtures for WKWebView; never contacts Naver or uses user data."""
from http.server import BaseHTTPRequestHandler, HTTPServer

MAIN = '''<!doctype html><meta name="viewport" content="width=device-width">
<iframe id="entryIframe" src="http://127.0.0.1:8349/restaurant/101/home"></iframe>
<iframe id="myPlaceBookmarkListIframe" src="http://127.0.0.2:8349/save-pages/pc/detail-list/fixture-folder"></iframe>
<span id="clickCount">0</span>
<button aria-expanded="true" onclick="this.setAttribute('aria-expanded',this.getAttribute('aria-expanded')==='true'?'false':'true')">패널 접기</button>
<script>addEventListener('message',event=>{if(event.data==='fixtureClick')document.querySelector('#clickCount').textContent=Number(document.querySelector('#clickCount').textContent)+1;});</script>'''

LIST = '''<!doctype html><meta name="viewport" content="width=device-width">
<header><h1>테스트 거래처 목록</h1><span>저장된 장소 수</span><span>25개</span></header>
<button aria-pressed="true">전체</button><ul id="rows"></ul>
<script>
let loaded=0;function append(end){for(;loaded<end;loaded++){let row=document.createElement('li');row.setAttribute('role','button');row.className='_place_info_card_fixture';row.style.height='120px';row.innerHTML='<strong class="_main_title_fixture"><span aria-hidden="true">거래처 '+loaded+'</span><span class="_blind_fixture">거래처 '+loaded+'</span></strong><span class="_place_info_item_fixture">서울 중구 세종대로 '+loaded+'</span>';row.onclick=()=>parent.postMessage('fixtureClick','http://localhost:8349');document.querySelector('#rows').append(row);}}
append(20);addEventListener('scroll',()=>{if(loaded===20)append(25);});
</script>'''

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        if self.path == '/main':
            content = MAIN
        elif '/detail-list/' in self.path:
            content = LIST
        else:
            name = '첫 번째 거래처' if '/101/' in self.path else '두 번째 거래처'
            content = f'<!doctype html><h1>{name}</h1><div><strong>주소</strong><span class="pz7wy">서울 중구 세종대로 1</span></div>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(content.encode())

HTTPServer(('0.0.0.0', 8349), Handler).serve_forever()
