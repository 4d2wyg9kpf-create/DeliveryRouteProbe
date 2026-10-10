/* Official NAVER API HUB, legacy Search and new Maps; conservative free-only gates. */
var DeliveryNaverAPI=(function(){
  'use strict';
  const places=typeof DeliveryNaverPlaces!=='undefined'?DeliveryNaverPlaces:require('./naver_places.js');
  const copy=x=>JSON.parse(JSON.stringify(x)),fail=m=>{throw Error(m);};
  const tidy=x=>String(x||'').replace(/\s+/g,' ').trim();
  const limits={search:25000,hub:25000,hubMonth:775000,maps:3000000},grace=300000;
  function text(x,max,label){if(typeof x!=='string'||x.length>max||/[\x00-\x1f\x7f]/.test(x))fail(label+' 형식을 확인해 주세요.');return tidy(x);}
  function title(x){
    return text(x,2000,'검색 이름').replace(/<[^>]*>/g,'').replace(/&(?:amp|lt|gt|quot|apos|nbsp|#\d+|#x[0-9a-f]+);/gi,s=>{
      const named={'&amp;':'&','&lt;':'<','&gt;':'>','&quot;':'"','&apos;':"'",'&nbsp;':' '};
      if(named[s])return named[s];const n=s[2].toLowerCase()==='x'?parseInt(s.slice(3,-1),16):parseInt(s.slice(2,-1),10);
      return n>31&&n<=0x10ffff?String.fromCodePoint(n):'';
    }).trim();
  }
  function seed(input){
    const address=text(input.address,1000,'주소'),name=text(input.name||address,500,'장소 이름');
    if(!name||!places.addressMatches(address,address))fail('시·구와 건물 번호가 포함된 전체 주소를 입력해 주세요.');
    return places.validate({version:1,kind:'address',selectionKey:'address:'+name.replace(/\s/g,'')+':'+address.replace(/\s/g,''),placeID:'',name,address,roadAddress:address,jibunAddress:'',
      sourceURL:'https://map.naver.com/p/search/'+encodeURIComponent(name+' '+address),coordinate:null,point:null,tileZoom:null,screenResolutionMeters:null,coordinateIssue:'주소 좌표 변환이 필요합니다.',capturedAt:new Date(input.now).toISOString(),method:'rendered_selected_address_panel'});
  }
  function local(input){
    const r=input.response;if(!r||!Array.isArray(r.items)||r.items.length>5)fail('네이버 지역 검색 응답 형식을 확인해 주세요.');
    const results=[];
    for(const row of r.items){
      try{
        const name=title(row.title),road=text(row.roadAddress||'',1000,'도로명주소'),jibun=text(row.address||'',1000,'지번주소');
        const capture=seed({name,address:road||jibun,now:input.now});capture.roadAddress=road;capture.jibunAddress=jibun;
        const evidence={provider:input.provider==='hub'?'NAVER API HUB':'NAVER Search',name,roadAddress:road,jibunAddress:jibun,x:String(row.mapx),y:String(row.mapy)};
        results.push({capture:places.apiCoordinate({capture,evidence}),category:text(row.category||'',500,'분류')});
      }catch(e){/* Invalid/obsolete coordinates never become selectable locations. */}
    }
    if(r.items.length&&!results.length)fail('검색 결과에 유효한 WGS84 좌표가 없습니다. 전체 주소로 좌표 변환을 시도해 주세요.');
    return results;
  }
  function choose(input){
    const capture=places.validate(input.capture),results=input.results;
    if(!Array.isArray(results))fail('지역 검색 결과를 확인해 주세요.');
    const matches=results.filter(r=>places.customerMatches({first:capture,second:r.capture}));
    if(!matches.length)fail('이름과 전체 주소가 일치하는 검색 결과가 없습니다. Maps 주소 변환 키를 설정해 주세요.');
    const first=matches[0].capture;
    if(matches.some(r=>distance(r.capture.coordinate,first.coordinate)>5))fail('같은 장소에 여러 좌표가 있습니다. 주소를 더 정확히 입력해 주세요.');
    return places.apiCoordinate({capture,evidence:first.apiEvidence});
  }
  function distance(a,b){const k=Math.PI/180;return Math.hypot((a.longitude-b.longitude)*k*Math.cos((a.latitude+b.latitude)/2*k),(a.latitude-b.latitude)*k)*6371000;}
  function geocode(input){
    const c=places.validate(input.capture),r=input.response;
    if(r?.status!=='OK'||!Array.isArray(r.addresses)||r.addresses.length>100)fail('네이버 Maps 주소 변환 응답을 확인해 주세요.');
    const matches=[];
    for(const row of r.addresses){
      try{matches.push(places.apiCoordinate({capture:c,evidence:{provider:'NAVER Maps',name:c.name,roadAddress:text(row.roadAddress||'',1000,'도로명주소'),jibunAddress:text(row.jibunAddress||'',1000,'지번주소'),x:text(String(row.x),50,'경도'),y:text(String(row.y),50,'위도')}}));}catch(e){}
    }
    if(!matches.length)fail('전체 주소와 건물 번호가 일치하는 좌표를 찾지 못했습니다. 주소를 확인해 주세요.');
    if(matches.some(v=>distance(v.coordinate,matches[0].coordinate)>5))fail('같은 주소에 여러 좌표가 있습니다. 상세 주소를 확인해 주세요.');
    return matches[0];
  }
  function period(provider,now){
    const d=new Date(now+9*3600000),year=d.getUTCFullYear(),month=d.getUTCMonth(),day=d.getUTCDate();
    const monthly=provider==='maps'||provider==='hubMonth',key=year+'-'+String(month+1).padStart(2,'0')+(monthly?'':'-'+String(day).padStart(2,'0'));
    const start=Date.UTC(year,month,monthly?1:day)-9*3600000;
    const reset=Date.UTC(year,monthly?month+1:month,monthly?1:day+1)-9*3600000+grace;
    return {key,reset,inGrace:now<start+grace};
  }
  function gate(input,operation){
    const prefix={search:'search:',hub:'hub:',hubMonth:'hub-month:',maps:'maps-'}[input.provider];
    if(!prefix||!Number.isFinite(input.now)||input.now<1577836800000||input.now>4102444800000||!/^(?:search|hub|hub-month):[a-f0-9]{64}$|^maps-free$/.test(input.key)||!input.key.startsWith(prefix))fail('API 사용량 기준 정보를 확인해 주세요.');
    const l=copy(input.ledger);
    if(!l||l.version!==1||!l.accounts||typeof l.accounts!=='object'||Array.isArray(l.accounts))fail('사용량 기록을 읽지 못해 호출을 차단했습니다.');
    const p=period(input.provider,input.now),limit=limits[input.provider];let a=l.accounts[input.key];
    if(a){
      if(!Number.isSafeInteger(a.used)||a.used<0||a.used>limit||!Number.isFinite(a.lastTrustedMs)||!Number.isFinite(a.resetMillis)||typeof a.period!=='string'||typeof a.blocked!=='boolean')fail('사용량 기록 오류로 호출을 차단했습니다.');
      if(input.now<a.lastTrustedMs-30000)fail('기준 시간이 이전 기록보다 오래되었습니다. 다시 확인해 주세요.');
      if(a.period!==p.key&&input.now>=a.resetMillis&&!p.inGrace)a=null;
    }
    if(!a)a={period:p.key,used:0,blocked:false,resetMillis:p.reset,lastTrustedMs:input.now};
    a.lastTrustedMs=Math.max(a.lastTrustedMs,input.now);
    if(operation==='reserve'){
      if(input.provider==='maps'&&input.freeConfirmed!==true)fail('새 Maps의 무료 대표 계정 여부를 설정에서 확인해 주세요.');
      if(['hub','hubMonth'].includes(input.provider)&&input.freeConfirmed!==true)fail('설정에서 NAVER API HUB가 현재 무료로 제공되는지 확인해 주세요.');
      if(p.inGrace)fail('한도 초기화 확인 시간입니다. 한국시간 00:05 이후 다시 사용해 주세요.');
      if(a.blocked||a.used>=limit)fail('무료 한도가 소진되어 다음 초기화까지 요청을 차단했습니다.');
      a.used++;
    }else if(operation==='raise'){
      if(p.inGrace)fail('한국시간 00:05 이후 사용량을 반영해 주세요.');
      if(!Number.isSafeInteger(input.used)||input.used<a.used||input.used>limit)fail('사용 횟수는 현재 기록 이상, 무료 한도 이하로 입력해 주세요.');
      a.used=input.used;
    }else if(operation==='block'){a.blocked=true;}
    l.accounts[input.key]=a;
    return {ledger:l,quota:{provider:input.provider,limit,used:a.used,remaining:a.blocked?0:limit-a.used,blocked:a.blocked||a.used>=limit||p.inGrace,resetMillis:a.resetMillis,inGrace:p.inGrace}};
  }
  const api={seed,local,geocode,choose,refresh:i=>gate(i,'refresh'),reserve:i=>gate(i,'reserve'),raise:i=>gate(i,'raise'),block:i=>gate(i,'block')};
  for(const key of Object.keys(api))api[key+'JSON']=value=>{try{return JSON.stringify({ok:true,value:api[key](JSON.parse(value))});}catch(e){return JSON.stringify({ok:false,message:e.message});}};
  return api;
})();
if(typeof module!=='undefined')module.exports=DeliveryNaverAPI;
