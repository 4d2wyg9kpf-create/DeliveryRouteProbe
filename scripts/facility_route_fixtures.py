"""Local fixtures shaped from observed public NAVER/Kakao DOM, with misleading unrelated numbers."""
import http.server, threading, subprocess, sys
from urllib.parse import urlparse, parse_qs
STYLE='<style>body{margin:0;font:16px sans-serif}.card{display:block;width:280px;min-height:50px;padding:8px}.outside{position:relative;left:1100px}.blind,.screen_out{position:absolute;width:1px;height:1px;overflow:hidden}button{min-width:40px;min-height:30px}dialog{position:relative;margin:0}.popup{max-height:100px;overflow:auto}</style>'
NAVER_WALK='''<section><header><h2>빠른길찾기</h2></header><button>출발지와 도착지 전환</button><div role="tab" aria-selected="true">도보</div><div>축척 250m · 99분 광고 · 9,900원</div><a class="card"><b>추천</b><div><span class="blind">소요시간</span><strong>1시간 3분</strong></div><div><span class="blind">거리</span><span>3.7km</span></div><div>걸음 수 5,880 걸음</div></a><a class="card"><b>계단회피</b><div><span class="blind">소요시간</span><strong>34분</strong></div><div><span class="blind">거리</span><span>1.7km</span></div></a></section>'''
NAVER_TRANSIT='''<section><header><h2>빠른길찾기</h2></header><button>출발지와 도착지 전환</button><div role="tab" aria-selected="true">대중교통</div><a class="card"><b>최적</b><div><div><span class="blind">소요시간</span><span>45분</span></div><span>요금 4,450원</span></div><span>8분 719번 12분 25분</span></a><a class="card"><div><span class="blind">소요시간</span><span>1시간 10분</span></div><span>요금 5,900원</span><span>55분 15분</span></a></section>'''
CAR='''<div id="section_content"><div role="tab" aria-selected="true">자동차</div><div role="button" aria-pressed="true" class="card outside"><div class="route_summary_box"><span class="summary_label_text">거리우선</span><div class="route_summary_info_duration"><strong>10분</strong><span class="item_distance">2.5km</span></div><div>택시비 8,900원 · 연료비 450원</div></div></div><button class="later_departure_btn" onclick="document.getElementById('later').showModal()">나중에 출발</button></div>'''
NAVER_FUTURE='''<dialog id="later"><button class="later_departure_time_btn" onclick="showCalendar()">출발 시간 변경</button><p class="later_depature_text">10월 12일 오후 7시 00분 출발하면</p><em class="later_depature_time_text"><strong class="later_departure_time">10분</strong> 소요 예상</em><div>30분 후 -4분 · 1시간 후 -6분</div></dialog><script>
function choices(button,values){let box=document.createElement('div');for(let value of values){let e=document.createElement('button');e.setAttribute('role','option');e.textContent=value;e.onclick=()=>{button.textContent=value;box.remove()};box.append(e)}button.after(box)}
function showCalendar(){document.getElementById('later').innerHTML=`<button class="calendar_date_btn" onclick="choices(this,['2026.10','2026.11'])">2026.10</button><button class="calendar_day_btn" aria-current="true" onclick="day(this)">1</button><button class="calendar_day_btn" aria-current="false" onclick="day(this)">2</button><div class="later_departure_calendar_date_btn_wrap"><button class="dropdown_btn" onclick="choices(this,['오전','오후'])">오후</button><button class="dropdown_btn" onclick="choices(this,['8시','9시'])">9시</button><button class="dropdown_btn" onclick="choices(this,['00분','30분'])">30분</button></div><button class="later_departure_confirm_btn" onclick="confirmTime()">확인</button>`}
function day(e){document.querySelectorAll('.calendar_day_btn').forEach(x=>x.setAttribute('aria-current','false'));e.setAttribute('aria-current','true')}
function confirmTime(){document.getElementById('later').innerHTML='<p class="later_depature_text">11월 2일 오전 8시 00분 출발하면</p><em class="later_depature_time_text"><strong class="later_departure_time">18분</strong> 소요 예상</em><div>30분 후 -4분 · 1시간 후 -6분</div>'}
</script>'''
KAKAO_FORM='''<form id="routeSearchForm"><input type="hidden" name="startLoc" value="출발"><input type="hidden" name="endLoc" value="도착"><input type="hidden" name="sxEnc" value="A"><input type="hidden" name="syEnc" value="B"><input type="hidden" name="exEnc" value="C"><input type="hidden" name="eyEnc" value="D"></form>'''
KAKAO_WALK='''<main><a class="link_summary walk_summary card"><h3 class="screen_out">도보 길찾기 요약 정보</h3><span class="info_route"><span class="txt_route"><span class="screen_out">소요 시간</span>1시간 29분</span><span class="txt_routeinfo"><span class="screen_out">거리</span>1.7km</span><span>지하도 1회 87kcal</span></span></a><div>지도 축척 500m</div></main>'''
KAKAO_TRANSIT='''<main><ul><li data-ranking="1" data-ptype="SUBWAY" class="card"><div class="public_info"><strong class="screen_out">총 소요 시간</strong><span class="txt_time">13분</span><span>카드 1,550원</span></div><span class="bar_timespend">5분 2분 5분</span><div>1호선 서울역 시청역 5번 출구</div></li><li data-ranking="2" data-ptype="BUS" class="card"><div class="public_info"><strong class="screen_out">총 소요 시간</strong><span class="txt_time">1시간 17분</span><span>1,500원</span></div><span>9분 6분 3분 · 7011번</span></li></ul></main>'''
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        p=urlparse(self.path);q=parse_qs(p.query);fixture=q.get('fixture',[''])[0]
        if p.path.startswith('/p/directions/'): body=CAR+(NAVER_FUTURE if fixture=='future' else '')
        elif p.path=='/actions/walkRoute': body=KAKAO_FORM+KAKAO_WALK
        elif p.path=='/actions/publicRoute': body=KAKAO_FORM+KAKAO_TRANSIT
        else: body=NAVER_TRANSIT if fixture=='transit' else NAVER_WALK
        if fixture=='outside': body=body.replace('class="card"','class="card outside"')
        if fixture=='hidden': body=body.replace('class="card"','class="card" style="display:none"')
        content=('<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">'+STYLE+body).encode()
        self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(content)));self.end_headers();self.wfile.write(content)
server=http.server.ThreadingHTTPServer(('127.0.0.1',8392),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
try: sys.exit(subprocess.call(sys.argv[1:],timeout=180))
finally: server.shutdown()
