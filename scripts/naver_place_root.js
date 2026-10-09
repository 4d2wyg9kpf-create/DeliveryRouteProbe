function readNaverPlaceRoot() {
  'use strict';
  const tidy=x=>String(x||'').replace(/\s+/g,' ').trim();
  const out=x=>JSON.stringify(x);
  const blocked=message=>out({ok:false,message});
  const rect=e=>{const r=e.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};};
  const shown=e=>{
    if(!e||!e.getClientRects().length)return false;
    for(let p=e;p&&p.nodeType===1;p=p.parentElement){const s=getComputedStyle(p);if(s.display==='none'||s.visibility==='hidden'||s.visibility==='collapse'||s.opacity==='0')return false;}
    return true;
  };
  const axisAligned=e=>{
    for(let p=e;p&&p.nodeType===1;p=p.parentElement){
      const t=getComputedStyle(p).transform||'none';if(t==='none')continue;
      let m=/^matrix\(([^)]+)\)$/.exec(t);
      if(m){const v=m[1].split(',').map(Number);if(v.length!==6||v.some(x=>!Number.isFinite(x))||Math.abs(v[1])>1e-6||Math.abs(v[2])>1e-6||v[0]<=0||v[3]<=0)return false;continue;}
      m=/^matrix3d\(([^)]+)\)$/.exec(t);
      if(m){const v=m[1].split(',').map(Number);if(v.length!==16||v.some(x=>!Number.isFinite(x))||v[0]<=0||v[5]<=0||v[10]!==1||v[15]!==1||[1,2,3,4,6,7,8,9,11].some(i=>Math.abs(v[i])>1e-6))return false;continue;}
      return false;
    }
    return true;
  };
  let url;try{url=new URL(location.href);}catch(_){return blocked('네이버 지도에서 장소나 주소를 선택해 주세요.');}
  if(url.protocol!=='https:'||url.hostname!=='map.naver.com')return blocked('네이버 지도에서 장소나 주소를 선택해 주세요.');
  if([...document.querySelectorAll('input[role="combobox"]')].some(e=>shown(e)&&e.getAttribute('aria-expanded')==='true'))return blocked('검색어 입력을 마치고 결과의 장소를 선택한 뒤 읽어 주세요.');
  const maps=[...document.querySelectorAll('.mantle_map')].filter(shown);
  const map=maps.length===1?maps[0]:null;
  const selectedIcon=e=>[...e.querySelectorAll('img')].some(image=>{
    if(!shown(image))return false;
    try{const src=new URL(image.getAttribute('src')||'',url.href);return src.protocol==='https:'&&src.hostname==='map.pstatic.net'&&src.pathname.startsWith('/resource/api/v2/image/maps/selected-marker/');}catch(_){return false;}
  });
  const pins=map?[...map.querySelectorAll('[data-maps-overlay]')].filter(e=>
    shown(e.querySelector('.marker_icon_image_wrap')||e.querySelector('img'))&&(e.closest('.ENTRY_MARKER')||selectedIcon(e))):[];
  const pin=pins.length===1?pins[0]:null,markerName=tidy(pin?.querySelector('.marker_title')?.textContent);
  let kind='',placeID='',name=markerName,frameURL='',address='',roadAddress='',jibunAddress='';
  // A selected detail panel proves the place ID even when the phone layout
  // hides or omits the map marker. Marker visibility only gates coordinates.
  const frames=[...document.querySelectorAll('#entryIframe')].filter(shown);
  if(frames.length>1)return blocked('장소 상세 화면을 하나만 열고 다시 읽어 주세요.');
  const frame=frames[0];
  if(frame){
    let f;try{f=new URL(frame.getAttribute('src')||'',url.href);}catch(_){return blocked('선택 장소의 상세 화면을 기다린 뒤 다시 읽어 주세요.');}
    const m=/^\/(?:place|restaurant|cafe|hospital|beauty|hairshop|accommodation)\/(\d+)(?:\/|$)/.exec(f.pathname);
    if(f.protocol!=='https:'||f.hostname!=='pcmap.place.naver.com'||!m)return blocked('선택한 장소 상세 화면을 읽지 못했습니다.');
    const selected=/\/entry\/place\/(\d+)(?:\/|$)/.exec(url.pathname);
    if(selected&&selected[1]!==m[1])return blocked('지도와 상세 패널의 장소가 다릅니다. 잠시 뒤 다시 읽어 주세요.');
    kind='place';placeID=m[1];frameURL=f.href;
  }else{
    const titles=[...document.querySelectorAll('.address_info_area .address_title')].filter(shown);
    if(titles.length!==1)return blocked('검색 또는 저장 목록에서 장소 하나를 선택해 주세요.');
    const panel=titles[0].closest('.scroll_box')||titles[0].closest('.scroll_area');
    const names=panel?[...panel.querySelectorAll('.title_box .title')].filter(shown):[];
    if(names.length!==1)return blocked('주소 검색 결과를 하나로 구분하지 못했습니다.');
    kind='address';name=tidy(names[0].textContent);address=roadAddress=tidy(titles[0].textContent);
    if(!name||!address)return blocked('선택한 주소가 표시된 상세 패널을 열어 주세요.');
    if(markerName&&!name.replace(/\s/g,'').includes(markerName.replace(/\s/g,'')))return blocked('주소 패널과 지도 표식이 다릅니다. 주소를 다시 선택해 주세요.');
    const labels=[...panel.querySelectorAll('.label_address_land')];
    if(labels.length===1){const row=labels[0].parentElement.cloneNode(true);row.querySelectorAll('.label_address_land,button,a,[role="button"]').forEach(e=>e.remove());jibunAddress=tidy(row.textContent);}
  }
  const selectionKey=kind==='place'?'place:'+placeID:'address:'+name.replace(/\s/g,'')+':'+address.replace(/\s/g,'');
  const base={ok:true,message:'선택 장소를 읽었습니다.',kind,selectionKey,placeID,name,frameURL,address,roadAddress,jibunAddress,
    sourceURL:kind==='place'?'https://map.naver.com/p/entry/place/'+placeID:url.origin+url.pathname,
    coordinate:null,mercatorX:null,mercatorY:null,tileZoom:null,screenResolutionMeters:null,point:null,coordinateIssue:''};
  const partial=message=>out({...base,coordinateIssue:message});
  if(!map)return partial('선택 장소의 이름·주소는 상세 패널에서 읽습니다. 좌표도 가져오려면 일반 지도가 보이도록 표시하고 다시 읽어 주세요.');
  if(!pin||!markerName)return partial('선택 장소의 지도 핀을 확인할 수 없어 주소만 읽습니다. 좌표가 필요하면 지도를 표시하고 장소를 다시 선택해 주세요.');
  const view=(url.searchParams.get('c')||'').split(',');
  if(view.length&&view.length!==1&&(!view.slice(0,4).every(x=>Number.isFinite(Number(x)))||Number(view[1])!==0||Number(view[2])!==0))return partial('지도의 회전·기울기를 해제하고 다시 읽으면 좌표를 가져올 수 있습니다.');
  if(!axisAligned(pin)||!axisAligned(map))return partial('지도 회전이나 변형이 있어 좌표를 확정하지 않았습니다.');
  const p=rect(pin),mr=rect(map);
  if(p.width!==0||p.height!==0)return partial('선택 표식의 기준점 구조가 달라 좌표를 확정하지 않았습니다.');
  if(p.x<Math.max(mr.x,0)||p.y<Math.max(mr.y,0)||p.x>Math.min(mr.x+mr.width,innerWidth)||p.y>Math.min(mr.y+mr.height,innerHeight))return partial('선택 표식이 화면에 보이도록 지도를 이동한 뒤 다시 읽어 주세요.');
  const hit=document.elementFromPoint(p.x,p.y);
  if(!hit||!map.contains(hit))return partial('선택 표식이 패널에 가려져 있습니다. 지도를 넓게 표시한 뒤 다시 읽어 주세요.');
  const tiles=[];
  for(const image of map.querySelectorAll('img')){
    if(!shown(image))continue;
    const t=/^https:\/\/map\.pstatic\.net\/nrb\/styles\/basic\/\d+\/(\d+)\/(\d+)\/(\d+)\.png(?:\?[^#]*)?$/.exec(image.getAttribute('src')||''),r=rect(image);
    if(!t)continue;
    if(!axisAligned(image)||r.width<64||r.width>1024||Math.abs(r.width-r.height)>0.01)return partial('지도 조각의 변형이 있어 좌표를 확정하지 않았습니다. 이동이 끝난 뒤 다시 읽어 주세요.');
    if(r.x+r.width<Math.max(mr.x,0)||r.y+r.height<Math.max(mr.y,0)||r.x>Math.min(mr.x+mr.width,innerWidth)||r.y>Math.min(mr.y+mr.height,innerHeight))continue;
    const z=+t[1],x=+t[2],y=+t[3],n=2**z;if(z<0||z>23||x>=n||y>=n)return partial('지도 조각 번호가 맞지 않아 좌표를 확정하지 않았습니다.');
    tiles.push({z,x,y,r});
  }
  if(tiles.length<3||new Set(tiles.map(t=>t.z)).size!==1||new Set(tiles.map(t=>t.x)).size<2||new Set(tiles.map(t=>t.y)).size<2)return partial('일반 지도 조각을 충분히 읽지 못했습니다. 확대·이동이 끝난 뒤 다시 읽어 주세요.');
  const z=tiles[0].z,width=tiles[0].r.width,n=2**z,origin={x:tiles[0].r.x-tiles[0].x*width,y:tiles[0].r.y-tiles[0].y*width};
  if(tiles.some(t=>Math.abs(t.r.width-width)>0.01||Math.hypot(t.r.x-t.x*width-origin.x,t.r.y-t.y*width-origin.y)>0.75))return partial('지도 조각 위치가 맞지 않습니다. 지도 이동이 끝난 뒤 다시 읽어 주세요.');
  const half=20037508.342789244,nx=(p.x-origin.x)/(width*n),ny=(p.y-origin.y)/(width*n),mercatorX=(nx*2-1)*half,mercatorY=(1-ny*2)*half;
  const longitude=nx*360-180,latitude=Math.atan(Math.sinh(Math.PI*(1-2*ny)))*180/Math.PI;
  const resolution=2*half*Math.cos(latitude*Math.PI/180)/(width*n)*2;
  if(!Number.isFinite(longitude)||!Number.isFinite(latitude)||longitude<124||longitude>132||latitude<32||latitude>40)return partial('표식 좌표가 국내 지도 범위를 벗어나 가져오지 않았습니다.');
  if(resolution>5)return partial('좌표 판독을 위해 지도를 더 확대한 뒤 다시 읽어 주세요.');
  base.coordinate={longitude,latitude};base.mercatorX=mercatorX;base.mercatorY=mercatorY;base.tileZoom=z;base.screenResolutionMeters=resolution;
  base.point={name,token:mercatorX.toFixed(3)+','+mercatorY.toFixed(3)+','+encodeURIComponent(name)+',,SIMPLE_POI'};
  return out(base);
}
