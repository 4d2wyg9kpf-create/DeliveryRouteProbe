function installNaverFrameBridge(detailReader, listReader) {
  'use strict';
  const channel='delivery-naver-dom-v2';
  if(location.protocol!=='https:'||!['pcmap.place.naver.com','pages.map.naver.com'].includes(location.hostname))return;
  const jobs=new Map();
  window.addEventListener('message',event=>{
    const request=event.data;
    if(event.origin!=='https://map.naver.com'||event.source!==window.parent||!request||request.channel!==channel||!/^[-a-zA-Z0-9]{16,80}$/.test(request.requestID||''))return;
    const allowed=location.hostname==='pcmap.place.naver.com'?request.kind==='place'&&request.command==='read':request.kind==='list'&&['read','select'].includes(request.command);
    if(!allowed)return;
    if(!jobs.has(request.requestID)){
      if(jobs.size>=12)jobs.delete(jobs.keys().next().value);
      const job=(async()=>{
        try {
          let value;
          if(request.kind==='list')value=JSON.parse(await listReader(request.command,request.args||{}));
          else {
            const until=Date.now()+8000;
            do{value=JSON.parse(detailReader());if(value.ok)break;await new Promise(resolve=>setTimeout(resolve,180));}while(Date.now()<until);
          }
          return value;
        }catch(error){return {ok:false,message:error.message||'네이버 화면을 읽지 못했습니다.'};}
      })();
      jobs.set(request.requestID,job);
    }
    jobs.get(request.requestID).then(result=>event.source.postMessage({channel,requestID:request.requestID,kind:request.kind,result},event.origin));
  });
}
