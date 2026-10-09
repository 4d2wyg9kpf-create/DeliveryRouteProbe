async readerSource => {
  // Only visible UI controls: detail, guide scrolling, arrival, zoom.
  const read=(0,eval)('('+readerSource+')');
  const shown=e=>!!e&&e.getClientRects().length>0&&getComputedStyle(e).display!=='none'&&getComputedStyle(e).visibility!=='hidden';
  const text=e=>String(e?.innerText||e?.textContent||'').replace(/\s+/g,' ').trim();
  const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  let before=JSON.parse(read());
  if(before.phase==='blocked')throw Error(before.message);
  const key=before.routeKey,selection=before.selection,index=before.selectedIndex;
  const check=()=>{
    const s=JSON.parse(read());
    if(s.routeKey!==key||s.selection!==selection||s.selectedIndex!==index)throw Error('읽는 동안 목적지나 자전거 경로가 바뀌었습니다. 다시 읽어 주세요.');
    return s;
  };
  let previous=null,actions=0,scrolls=0,focuses=0,zooms=0;
  for(let pass=0;pass<65;pass++){
    const s=check();
    if(s.ok){
      const signature=JSON.stringify([s.capture.point.token,s.capture.detailSummary,s.capture.tileZoom,s.capture.destinationGapMeters,s.screenPoint]);
      if(previous===signature)return JSON.stringify(s.capture);
      previous=signature;await pause(250);continue;
    }
    previous=null;
    // Transient geometry states get a bounded retry, not a made-up coordinate.
    if(s.phase==='blocked'){
      if(pass>0&&pass<64){await pause(200);continue;}
      throw Error(s.message);
    }
    if(s.phase==='detail'){
      const card=[...document.querySelectorAll('[role="tabpanel"] [aria-pressed="true"]')].find(e=>shown(e)&&e.querySelector('.direction_top_area'));
      const button=card?.querySelector('.btn_way_detail');
      if(!button||actions++>2)throw Error('자전거 상세보기를 열지 못했습니다.');
      button.click();
    }else if(s.phase==='arrival'){
      const rows=[...document.querySelectorAll('#sub_panel .direction_guide_item')];
      if(!rows.length||scrolls++>=22)throw Error('마지막 도착 안내를 불러오지 못했습니다. 상세 안내의 맨 아래로 이동한 뒤 다시 읽어 주세요.');
      rows.at(-1).scrollIntoView({block:'center',behavior:'instant'});
    }else if(s.phase==='focus'){
      const row=[...document.querySelectorAll('#sub_panel .direction_guide_item')].find(e=>e.querySelector('.direction_tbt_icon img[alt="목적지"]'));
      const button=row?.querySelector('.btn_direction');
      if(!button||focuses++>=3)throw Error('지도에서 도착 경로의 끝이 보이도록 이동해 주세요.');
      button.click();
    }else if(s.phase==='zoom'){
      const buttons=[...document.querySelectorAll('button')].filter(e=>shown(e)&&text(e)==='확대');
      if(buttons.length!==1||buttons[0].disabled||zooms++>=8)throw Error('입구를 읽을 만큼 지도를 확대하지 못했습니다.');
      buttons[0].click();
    }else throw Error('지도 화면의 단계를 확인하지 못했습니다.');
    await pause(350);
  }
  throw Error('지도 이동이 안정되지 않아 종점을 저장하지 않았습니다. 다시 읽어 주세요.');
}
