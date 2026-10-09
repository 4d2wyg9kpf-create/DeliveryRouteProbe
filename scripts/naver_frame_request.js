async function requestNaverFrame(kind,command,requestID,args) {
  'use strict';
  const channel='delivery-naver-dom-v2';
  if(location.protocol!=='https:'||location.hostname!=='map.naver.com')return JSON.stringify({ok:false,message:'네이버 지도에서 읽어 주세요.'});
  const selector=kind==='place'?'#entryIframe':'#myPlaceBookmarkListIframe';
  const expected=kind==='place'?'https://pcmap.place.naver.com':'https://pages.map.naver.com';
  const frames=[...document.querySelectorAll(selector)];
  if(frames.length!==1)return JSON.stringify({ok:false,message:kind==='place'?'장소 상세 화면을 하나 열어 주세요.':'네이버 저장 목록에서 가져올 폴더를 열어 주세요.'});
  const frame=frames[0];let url;try{url=new URL(frame.getAttribute('src'),location.href);}catch(_){return JSON.stringify({ok:false,message:'상세 화면이 열리는 중입니다. 다시 읽어 주세요.'});}
  if(url.origin!==expected)return JSON.stringify({ok:false,message:'네이버 상세 화면의 출처를 확인하지 못했습니다.'});
  // Request the CURRENT frame on every tap, rather than caching transient WKFrameInfo.
  return await new Promise(resolve=>{
    let timer,timeout,done=false;
    const finish=value=>{if(done)return;done=true;clearInterval(timer);clearTimeout(timeout);window.removeEventListener('message',receive);resolve(JSON.stringify(value));};
    const receive=event=>{
      const data=event.data;
      if(event.source!==frame.contentWindow||event.origin!==expected||data?.channel!==channel||data.requestID!==requestID||data.kind!==kind)return;
      let current;try{current=new URL(frame.getAttribute('src'),location.href).href;}catch(_){current='';}
      if(frame!==document.querySelector(selector)||current!==url.href){finish({ok:false,message:'읽는 동안 상세 화면이 바뀌었습니다. 다시 읽어 주세요.'});return;}
      finish(data.result||{ok:false,message:'상세 화면에서 빈 응답이 왔습니다.'});
    };
    const send=()=>{
      if(!frame.isConnected){finish({ok:false,message:'읽는 동안 상세 화면이 닫혔습니다.'});return;}
      frame.contentWindow.postMessage({channel,kind,command,requestID,args},expected);
    };
    window.addEventListener('message',receive);
    timeout=setTimeout(()=>finish({ok:false,message:'네이버 상세 화면의 응답이 지연됐습니다. 새로고침 후 다시 읽어 주세요.'}),kind==='list'&&command==='read'?35000:12000);
    timer=setInterval(send,300);send();
  });
}
