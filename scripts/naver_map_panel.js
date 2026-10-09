async function setNaverMapPanel(showMap) {
  'use strict';
  if(location.protocol!=='https:'||location.hostname!=='map.naver.com')return JSON.stringify({ok:false,message:'네이버 지도 화면에서 전환해 주세요.'});
  const button=[...document.querySelectorAll('button[aria-expanded]')].find(e=>/패널 (접기|펼치기)/.test(e.textContent));
  if(!button)return JSON.stringify({ok:false,message:'지도 패널 버튼이 준비되지 않았습니다. 로딩 후 다시 눌러 주세요.'});
  const expanded=button.getAttribute('aria-expanded')==='true';
  if(expanded===showMap)button.click();
  await new Promise(resolve=>setTimeout(resolve,300));
  return JSON.stringify({ok:true,mapVisible:button.getAttribute('aria-expanded')==='false'});
}
