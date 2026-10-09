(scopeOnly = false) => {
  // Read rendered DOM/SVG/raster tile placement only. No map SDK, fetch,
  // panorama coordinates, private page state or guessed POI-to-entrance offset.
  const tidy=x=>String(x||'').replace(/\s+/g,' ').trim();
  const text=e=>tidy(e?.innerText||e?.textContent);
  const all=(r,s)=>Array.from(r.querySelectorAll(s));
  const shown=e=>!!e&&e.getClientRects().length>0&&getComputedStyle(e).display!=='none'&&getComputedStyle(e).visibility!=='hidden';
  const out=(phase,message,extra={})=>JSON.stringify({ok:phase==='ready',phase,message,...extra});
  const url=location.href;
  const m=/^https:\/\/map\.naver\.com\/p\/directions\/([^/?#]+)\/([^/?#]+)\/-\/bike(?:\/(\d+))?(?:\?[^#]*)?$/.exec(url);
  if(!m)return out('blocked','경유지 없는 자전거 길찾기 결과를 먼저 열어 주세요.');
  const point=raw=>{const p=raw.split(',');if(p.length!==5)return null;try{const name=decodeURIComponent(p[2]);p[2]=encodeURIComponent(name);return{token:p.join(','),name};}catch(_){return null;}};
  const start=point(m[1]),destination=point(m[2]);
  if(!start?.name||!destination?.name)return out('blocked','출발·목적지 주소를 해석하지 못했습니다.');
  const routeKey=start.token+'/'+destination.token+'/bike';
  const base={routeKey,sourceURL:url,start,destination};
  const fail=(phase,message,extra={})=>out(phase,message,{...base,...extra});
  if(all(document,'dialog,[role="dialog"]').some(shown))return fail('blocked','열린 지도 설정창을 닫아 주세요.');
  const tabs=all(document,'[role="tab"][aria-selected="true"]').filter(shown);
  const inputs=all(document,'input[role="combobox"]').filter(shown).map(e=>tidy(e.value));
  if(tabs.length!==1||text(tabs[0])!=='자전거'||inputs.length!==2||inputs[0]!==tidy(start.name)||inputs[1]!==tidy(destination.name))return fail('blocked','입력한 장소와 표시된 자전거 경로가 일치하지 않습니다. 길찾기를 다시 실행해 주세요.');
  const cards=all(document,'[role="tabpanel"] [aria-pressed="true"]').filter(e=>shown(e)&&e.querySelector('.direction_top_area'));
  if(cards.length!==1)return fail('blocked','자전거 경로 한 개가 선택된 결과가 필요합니다.');
  const summary=e=>text(e?.querySelector('.direction_top_area'))+'|'+text(e?.querySelector('.bike_route_order_list'));
  const card=cards[0], selection=summary(card);
  if(!selection.includes('자전거 경로'))return fail('blocked','자전거 경로 요약을 확인하지 못했습니다.');
  const common={...base,selection,selectedIndex:m[3]===undefined?0:+m[3]};
  if(scopeOnly)return JSON.stringify({ok:true,...common});
  const result=(phase,message,extra={})=>out(phase,message,{...common,...extra});
  const detail=document.querySelector('#sub_panel');
  if(!shown(detail)||!detail.querySelector('.direction_guide_list'))return result('detail','자전거 상세 안내를 여는 중입니다.');
  if(summary(detail)!==selection||card.getAttribute('aria-expanded')!=='true')return result('blocked','선택한 경로와 상세 안내가 다릅니다.');
  const rows=all(detail,'.direction_guide_item');
  const starts=rows.filter(e=>e.querySelector('.direction_tbt_icon img[alt="출발지"]'));
  const goals=rows.filter(e=>e.querySelector('.direction_tbt_icon img[alt="목적지"]'));
  if(starts.length!==1||text(starts[0].querySelector('.btn_direction strong'))!==tidy(start.name))return result('blocked','출발지 상세 안내가 현재 검색과 다릅니다.');
  if(!goals.length)return result('arrival','마지막 도착 안내를 불러오는 중입니다.');
  if(goals.length!==1||goals[0]!==rows[rows.length-1]||text(goals[0].querySelector('.btn_direction strong'))!==tidy(destination.name))return result('blocked','목적지 상세 안내를 확정하지 못했습니다.');
  if(!goals[0].querySelector('.btn_direction.is_selected'))return result('focus','도착 위치로 지도를 이동하는 중입니다.');
  const c=url.match(/[?&]c=([^&]+)/)?.[1]?.split(',');
  if(!c||c.length<4||c.slice(1,4).some(x=>!/^0(?:\.0+)?$/.test(x)))return result('blocked','회전·기울임 없는 일반 지도로 표시해 주세요.');
  const maps=all(document,'[role="application"]').filter(shown);
  if(maps.length!==1)return result('blocked','지도 화면을 하나로 확인하지 못했습니다.');
  const map=maps[0], rect=e=>{const r=e.getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height};};
  const distance=(a,b)=>Math.hypot(a.x-b.x,a.y-b.y);
  // Only the observed absolute M/L path format is accepted; curves, multiple
  // subpaths and transformed paths fail closed instead of guessing an end.
  const parsePath=d=>{
    if(!/^\s*M\s*[-\d.,\s]+L\s*[-\d.,\s]+\s*$/.test(d||''))return null;
    const v=d.match(/-?\d+(?:\.\d+)?/g)?.map(Number);
    if(!v||v.length<4||v.length%2||v.some(x=>!Number.isFinite(x)))return null;
    return Array.from({length:v.length/2},(_,i)=>({x:v[i*2],y:v[i*2+1]}));
  };
  const axisAligned=e=>{
    for(let node=e;node&&node!==map.parentElement;node=node.parentElement){
      const t=getComputedStyle(node).transform;
      if(!t||t==='none')continue;
      const a=t.match(/^matrix\(([^)]+)\)$/)?.[1].split(',').map(Number);
      const b=t.match(/^matrix3d\(([^)]+)\)$/)?.[1].split(',').map(Number);
      if(a&&a.length===6&&a.every(Number.isFinite)&&a[0]>0&&a[3]>0&&Math.abs(a[1])+Math.abs(a[2])<1e-7)continue;
      if(b&&b.length===16&&b.every(Number.isFinite)&&b[0]>0&&b[5]>0&&b[10]===1&&b[15]===1&&[1,2,3,4,6,7,8,9,11,14].every(i=>Math.abs(b[i])<1e-7))continue;
      return false;
    }return true;
  };
  const paths=[];
  for(const svg of all(map,'svg')){
    if(!shown(svg)||!axisAligned(svg))continue;
    const vb=(svg.getAttribute('viewBox')||'').trim().split(/[ ,]+/).map(Number),r=rect(svg);
    if(vb.length!==4||vb.some(x=>!Number.isFinite(x))||vb[2]<=0||vb[3]<=0||r.width<=0||r.height<=0||Math.abs(r.width/vb[2]-r.height/vb[3])>1e-5)continue;
    for(const p of all(svg,'path')){
      const style=(p.getAttribute('style')||'').replace(/\s/g,'').toLowerCase(),v=parsePath(p.getAttribute('d'));
      if(!v||p.hasAttribute('transform')||!shown(p))continue;
      paths.push({d:p.getAttribute('d'),style,points:v.map(p=>({x:r.x+(p.x-vb[0])*r.width/vb[2],y:r.y+(p.y-vb[1])*r.height/vb[3]}))});
    }
  }
  const solid=paths.filter(p=>p.style.includes('stroke:#076cf2;')&&p.style.includes('stroke-width:9px;')&&!p.style.includes('stroke-dasharray'));
  const outlines=paths.filter(p=>p.style.includes('stroke:#04459b;')&&p.style.includes('stroke-width:12px;'));
  if(solid.length!==1||outlines.length!==1||solid[0].d!==outlines[0].d)return result('blocked','자전거 경로 선을 하나로 구분하지 못했습니다. 일반 지도에서 다시 읽어 주세요.');
  const line=solid[0],first=line.points[0],end=line.points[line.points.length-1];
  if(distance(end,outlines[0].points.at(-1))>0.5)return result('blocked','지도 경로 선이 아직 이동 중입니다.');
  const markers=all(map,'.DIRECTIONS_PIN_MARKER [data-maps-overlay]');
  const marker=label=>{const xs=markers.filter(e=>text(e)===label);return xs.length===1?rect(xs[0]):null;};
  const startPin=marker('출발'),goalPin=marker('도착');
  if(!startPin||!goalPin)return result('blocked','출발·도착 표시를 확인하지 못했습니다.');
  const connectors=paths.filter(p=>p.style.includes('stroke:#a7b0be;')&&p.style.includes('stroke-dasharray:1,12;'));
  const connects=(a,b)=>distance(a,b)<=1.5||connectors.some(p=>(distance(a,p.points[0])<=1.5&&distance(b,p.points.at(-1))<=1.5)||(distance(b,p.points[0])<=1.5&&distance(a,p.points.at(-1))<=1.5));
  if(!connects(first,startPin)||!connects(end,goalPin))return result('blocked','경로 선의 끝과 목적지 연결선을 함께 확인하지 못했습니다.');
  const mr=rect(map);
  if(end.x<Math.max(0,mr.x)||end.y<Math.max(0,mr.y)||end.x>Math.min(innerWidth,mr.x+mr.width)||end.y>Math.min(innerHeight,mr.y+mr.height))return result('focus','도착 경로의 끝이 보이도록 지도를 이동합니다.');
  const hit=document.elementFromPoint(end.x,end.y);
  if(!hit||!map.contains(hit))return result('blocked','도착 위치가 패널에 가려져 있습니다. 지도를 넓게 표시한 후 다시 읽어 주세요.');
  const tiles=[];
  for(const image of all(map,'img')){
    if(!shown(image)||!axisAligned(image))continue;
    const src=image.getAttribute('src')||'',t=/^https:\/\/map\.pstatic\.net\/nrb\/styles\/basic\/\d+\/(\d+)\/(\d+)\/(\d+)\.png(?:\?[^#]*)?$/.exec(src),r=rect(image);
    if(!t||r.width<64||r.width>1024||Math.abs(r.width-r.height)>0.01)continue;
    const z=+t[1],x=+t[2],y=+t[3],n=2**z;
    if(z<0||z>23||x>=n||y>=n)continue;
    tiles.push({z,x,y,r});
  }
  const z=Math.max(...tiles.map(t=>t.z));
  if(!Number.isFinite(z))return result('blocked','화면에 표시된 일반 지도 조각을 읽지 못했습니다.');
  if(z<19)return result('zoom','도착 경로의 끝을 확대하는 중입니다.',{tileZoom:z});
  const ts=tiles.filter(t=>t.z===z),n=2**z;
  if(ts.length<3||new Set(ts.map(t=>t.x)).size<2||new Set(ts.map(t=>t.y)).size<2)return result('blocked','좌표를 교차 확인할 지도 조각이 부족합니다.');
  const origins=ts.map(t=>({x:t.r.x-t.x*t.r.width,y:t.r.y-t.y*t.r.height})),origin=origins[0],width=ts[0].r.width;
  if(ts.some(t=>Math.abs(t.r.width-width)>0.01)||origins.some(o=>distance(o,origin)>0.75))return result('blocked','지도 조각 위치가 서로 다릅니다. 확대가 끝난 뒤 다시 읽어 주세요.');
  const half=20037508.342789244,nx=(end.x-origin.x)/(width*n),ny=(end.y-origin.y)/(width*n);
  const mercatorX=(nx*2-1)*half,mercatorY=(1-ny*2)*half;
  const longitude=mercatorX/half*180,latitude=Math.atan(Math.sinh(mercatorY/6378137))*180/Math.PI;
  if(!(longitude>=124&&longitude<=132&&latitude>=32&&latitude<=40))return result('blocked','계산한 좌표가 국내 지도 범위를 벗어납니다.');
  const metersPerPixel=2*half/(width*n)*Math.cos(latitude*Math.PI/180);
  const name=destination.name+' · 자전거 종점';
  const endpoint={token:mercatorX.toFixed(3)+','+mercatorY.toFixed(3)+','+encodeURIComponent(name)+',,SIMPLE_POI',name};
  const arrivalSideText=text(goals[0].querySelector('.btn_direction_detail_goal_desc'));
  return result('ready','자전거 경로 선의 끝점을 읽었습니다.',{
    capture:{version:1,sourceURL:url,routeKey,selectedIndex:common.selectedIndex,start,destination,point:endpoint,
      latitude,longitude,mercatorX,mercatorY,tileZoom:z,screenResolutionMeters:metersPerPixel*2,
      destinationGapMeters:distance(end,goalPin)*metersPerPixel,arrivalSideText,
      detailSummary:selection,finalInstruction:text(rows[rows.length-2]?.querySelector('.btn_direction strong')),
      guideCount:rows.length,capturedAt:new Date().toISOString(),method:'rendered_svg_and_tiles',
      previewURL:'https://map.naver.com/p/directions/'+start.token+'/'+endpoint.token+'/-/bike?c=18.00,0,0,0,dh'},
    screenPoint:end,tileZoom:z
  });
}
