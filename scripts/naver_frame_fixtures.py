"""Local DOM fixtures for WKWebView; never contacts Naver or uses user data."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from pathlib import Path
import subprocess
import sys
import urllib.request
import base64
import math

MAIN = '''<!doctype html><meta name="viewport" content="width=device-width">
<iframe id="entryIframe" src="http://127.0.0.1:8350/restaurant/101/home"></iframe>
<iframe id="myPlaceBookmarkListIframe" src="http://127.0.0.1:8351/save-pages/pc/detail-list/fixture-folder"></iframe>
<span id="clickCount">0</span>
<button aria-expanded="true" onclick="this.setAttribute('aria-expanded',this.getAttribute('aria-expanded')==='true'?'false':'true')">패널 접기</button>
<script>addEventListener('message',event=>{if(event.data==='fixtureClick')document.querySelector('#clickCount').textContent=Number(document.querySelector('#clickCount').textContent)+1;});</script>'''

LIST = '''<!doctype html><meta name="viewport" content="width=device-width">
<header><h1>테스트 거래처 목록</h1><span>저장된 장소 수</span><span>25개</span></header>
<button aria-pressed="true">전체</button><ul id="rows"></ul>
<script>
let loaded=0;function append(end){for(;loaded<end;loaded++){let row=document.createElement('li');row.setAttribute('role','button');row.className='_place_info_card_fixture';row.style.height='120px';row.innerHTML='<strong class="_main_title_fixture"><span aria-hidden="true">거래처 '+loaded+'</span><span class="_blind_fixture">거래처 '+loaded+'</span></strong><span class="_place_info_item_fixture">서울 중구 세종대로 '+loaded+'</span>';row.onclick=()=>parent.postMessage('fixtureClick','http://127.0.0.1:8349');document.querySelector('#rows').append(row);}}
append(20);addEventListener('scroll',()=>{if(loaded===20)append(25);});
</script>'''

# The zero-size anchor is a selected address pin, not a registered POI or the
# map center. Two points can share the identical visible address panel.
ZOOM = 18
TILE_X = math.floor((127.4 + 180) / 360 * 2 ** ZOOM)
TILE_Y = math.floor((1 - math.asinh(math.tan(math.radians(36.3))) / math.pi) / 2 * 2 ** ZOOM)
EXPECTED_LON = ((TILE_X + 196 / 256) / 2 ** ZOOM) * 360 - 180
EXPECTED_LAT = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (TILE_Y + 196 / 256) / 2 ** ZOOM))))
ADDRESS = f'''<!doctype html><meta name="viewport" content="width=device-width">
<style>body{{margin:0}}.scroll_box{{height:120px}}.mantle_map{{position:relative;width:393px;height:520px;overflow:hidden}}.tile{{position:absolute;width:256px;height:256px}}#pin{{position:absolute;width:0;height:0;left:196px;top:196px}}.marker_icon_image_wrap{{position:absolute;left:-10px;top:-20px;width:20px;height:20px}}.marker_title{{position:absolute;left:12px;top:-20px;width:150px;height:20px}}</style>
<div class="scroll_box"><div class="title_box"><span class="title">가상 주소 지점</span></div><div class="address_info_area"><span class="address_title">대전 중구 가상로 1</span></div></div>
<div class="mantle_map" data-longitude="{EXPECTED_LON}" data-latitude="{EXPECTED_LAT}">
''' + ''.join(f'<img class="tile" style="left:{dx * 256}px;top:{dy * 256}px" src="http://127.0.0.1:8349/nrb/styles/basic/1/{ZOOM}/{TILE_X + dx}/{TILE_Y + dy}.png">' for dx in [0, 1] for dy in [0, 1]) + '''
<div class="ENTRY_MARKER"><div id="pin" data-maps-overlay="selected"><span class="marker_icon_image_wrap"><img width="20" height="20" src="http://127.0.0.1:8349/resource/api/v2/image/maps/selected-marker/test.png"></span><span class="marker_title">가상 주소 지점</span></div></div></div>'''
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aOYcAAAAASUVORK5CYII=')

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        print("LOCAL_FIXTURE_HTTP", self.path, flush=True)
    def do_GET(self):
        if self.path.endswith('.png'):
            self.send_response(200)
            self.send_header('Content-Type', 'image/png')
            self.end_headers()
            self.wfile.write(PNG)
            return
        if self.path == '/main':
            content = MAIN
        elif self.path == '/address':
            content = ADDRESS
        elif '/detail-list/' in self.path:
            content = LIST
        else:
            name = '첫 번째 거래처' if '/101/' in self.path else '두 번째 거래처'
            content = f'<!doctype html><h1>{name}</h1><div><strong>주소</strong><span class="pz7wy">서울 중구 세종대로 1</span></div>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        self.wfile.write(content.encode())

def run_checks(binary):
    # Own the fixture servers and the native client in one foreground process.
    # Binding completes before the client starts, and exceptions reach CI.
    servers = []
    try:
        for port in [8349, 8350, 8351]:
            server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
            servers.append(server)
            Thread(target=server.serve_forever, daemon=True).start()
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for server in servers:
            with opener.open(f'http://127.0.0.1:{server.server_port}/main', timeout=5) as response:
                assert response.status == 200
        print('LOCAL_FIXTURE_SERVERS_READY', flush=True)
        return subprocess.run([str(Path(binary).resolve())], timeout=180).returncode
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Pass the compiled native fixture test executable')
    raise SystemExit(run_checks(sys.argv[1]))
