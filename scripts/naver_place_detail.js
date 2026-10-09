function readNaverPlaceDetail() {
  'use strict';
  const tidy=x=>String(x||'').replace(/\s+/g,' ').trim();
  const shown=e=>{if(!e||!e.getClientRects().length)return false;for(let p=e;p&&p.nodeType===1;p=p.parentElement){const s=getComputedStyle(p);if(s.display==='none'||s.visibility==='hidden'||s.opacity==='0')return false;}return true;};
  let url;try{url=new URL(location.href);}catch(_){return JSON.stringify({ok:false,message:'장소 상세 화면을 읽지 못했습니다.'});}
  const id=/^\/(?:place|restaurant|cafe|hospital|beauty|hairshop|accommodation)\/(\d+)(?:\/|$)/.exec(url.pathname);
  if(url.protocol!=='https:'||url.hostname!=='pcmap.place.naver.com'||!id)return JSON.stringify({ok:false,message:'네이버 장소 상세 화면에서 읽어 주세요.'});
  const names=[...document.querySelectorAll('.IY7ZX')].filter(shown);
  const name=names.length===1?tidy(names[0].textContent):tidy([...document.querySelectorAll('h1')].find(shown)?.textContent);
  if(!name)return JSON.stringify({ok:false,message:'장소 이름이 표시된 홈·정보 화면을 열고 다시 읽어 주세요.'});
  const labels=[...document.querySelectorAll('strong')].filter(e=>tidy(e.textContent)==='주소');
  let address='',roadAddress='',jibunAddress='';
  if(labels.length===1){
    const row=labels[0].parentElement;
    const first=[...row.querySelectorAll('.pz7wy')].find(shown);address=tidy(first?.textContent);
    for(const label of row.querySelectorAll('.TjXg1')){
      if(!shown(label))continue;
      const key=tidy(label.textContent),copy=label.parentElement.cloneNode(true);
      copy.querySelectorAll('.TjXg1,.S8peq,a,button').forEach(e=>e.remove());
      if(key==='도로명')roadAddress=tidy(copy.textContent);
      if(key==='지번')jibunAddress=tidy(copy.textContent);
    }
  }
  if(!address&&!roadAddress&&!jibunAddress)return JSON.stringify({ok:false,message:'장소 주소가 준비되지 않았습니다. 장소 홈 화면이 열린 뒤 다시 읽어 주세요.'});
  return JSON.stringify({ok:true,placeID:id[1],name,address,roadAddress,jibunAddress});
}
