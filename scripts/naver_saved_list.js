async function readNaverSavedList(command,args) {
  'use strict';
  const tidy=x=>String(x||'').replace(/\s+/g,' ').trim(),out=x=>JSON.stringify(x);
  const url=new URL(location.href),match=/^\/save-pages\/pc\/detail-list\/([a-zA-Z0-9_-]+)(?:\/|$)/.exec(url.pathname);
  if(url.protocol!=='https:'||url.hostname!=='pages.map.naver.com'||!match)return out({ok:false,message:'가져올 저장 폴더를 선택해 주세요. 폴더 안의 장소를 한 번에 가져옵니다.'});
  const folderID=match[1],wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const cards=()=>[...document.querySelectorAll('li[role="button"][class*="place_info_card"]')];
  const record=(row,index)=>{
    const title=row.querySelector('strong[class*="main_title"]')||row.querySelector('strong');
    const visible=title?.querySelector('[aria-hidden="true"]');
    const clean=title?.cloneNode(true);clean?.querySelectorAll('[class*="blind"]').forEach(e=>e.remove());
    const name=tidy(visible?.textContent||clean?.textContent);
    const fields=[...row.querySelectorAll('[class*="place_info_item"]')].map(e=>tidy(e.textContent));
    const address=fields.findLast(x=>/^(서울|부산|대구|인천|광주|대전|울산|세종|경기|강원|충청|충북|충남|전라|전북|전남|경상|경북|경남|제주)/.test(x))||'';
    return {index,name,address,key:name+'|'+address};
  };
  const header=()=>tidy(document.querySelector('header')?.textContent);
  const total=()=>{const m=/저장된 장소 수\s*([\d,]+)개/.exec(header());return m?Number(m[1].replace(/,/g,'')):null;};
  if(command==='select'){
    if(args.folderID!==folderID)return out({ok:false,message:'가져오는 중 저장 폴더가 바뀌었습니다.'});
    const rows=cards(),row=rows[args.index];
    if(!row||record(row,args.index).key!==args.key)return out({ok:false,message:'저장 목록의 순서나 장소가 바뀌었습니다. 목록을 다시 가져와 주세요.'});
    row.scrollIntoView({block:'center'});row.click();
    return out({ok:true,folderID,index:args.index,key:args.key});
  }
  if(command!=='read')return out({ok:false,message:'목록 읽기 요청을 확인해 주세요.'});
  if(/비공개|확인할 수 없습니다|로그인 후/.test(header()||tidy(document.body.textContent).slice(0,500)))return out({ok:false,message:'저장 목록을 열 수 없습니다. 네이버 로그인과 폴더 공개·접근 상태를 확인해 주세요.'});
  const all=[...document.querySelectorAll('button[aria-pressed]')].find(e=>tidy(e.textContent)==='전체');
  if(all&&all.getAttribute('aria-pressed')!=='true'){all.click();await wait(450);}
  const until=Date.now()+28000;let stable=0,last=-1;
  while(Date.now()<until){
    if(new URL(location.href).pathname!==url.pathname)return out({ok:false,message:'읽는 동안 저장 폴더가 바뀌었습니다.'});
    const expected=total(),rows=cards();
    if(expected!=null&&expected>1000)return out({ok:false,message:'한 번에 1,000곳까지 가져올 수 있습니다. 네이버에서 폴더를 나눠 주세요.'});
    if(expected!=null&&rows.length>=expected)break;
    if(rows.length===last)stable++;else{stable=0;last=rows.length;}
    if(stable>9)break;
    rows.at(-1)?.scrollIntoView({block:'end'});
    const scrollers=[document.scrollingElement,...document.querySelectorAll('div,ul')].filter(e=>e&&e.clientHeight>100&&e.scrollHeight>e.clientHeight+30);
    for(const element of scrollers)element.scrollTop=element.scrollHeight;
    await wait(500);
  }
  const expected=total(),rows=cards().map(record),title=tidy(document.querySelector('h1')?.textContent);
  if(expected==null)return out({ok:false,message:'저장 목록의 전체 개수를 확인하지 못했습니다. 목록 화면을 새로고침해 주세요.'});
  if(rows.length!==expected)return out({ok:false,message:'전체 '+expected+'곳 중 '+rows.length+'곳만 로딩됐습니다. 누락을 막기 위해 저장을 중지했습니다. 다시 가져와 주세요.'});
  if(rows.some(x=>!x.name))return out({ok:false,message:'이름이 없는 저장 항목이 있어 목록을 확인해 주세요.'});
  return out({ok:true,folderID,title,total:expected,rows});
}
