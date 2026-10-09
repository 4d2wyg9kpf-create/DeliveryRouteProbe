/* TMAP request/response and conservative quota accounting. No network or secrets here. */
var DeliveryTMap = (function () {
  'use strict';
  const specs = [{id:10,limit:50},{id:20,limit:50},{id:30,limit:1},{id:100,limit:1}];
  const dayMs = 86400000, offset = 9*3600000, grace = 5*60000;
  const copy = value => JSON.parse(JSON.stringify(value));
  const fail = message => { throw Error(message); };
  const integer = (v,lo,hi) => Number.isSafeInteger(v)&&v>=lo&&v<=hi;
  function service(count) {
    if (!integer(count,1,100)) fail('배송지는 1~100곳이어야 합니다.');
    return specs.find(s=>count<=s.id);
  }
  function epoch(now) {
    if (!Number.isFinite(now)||now<1577836800000||now>4102444800000) fail('서버 기준 시각을 확인하지 못했습니다.');
    return now;
  }
  function period(now) { return new Date(epoch(now)+offset-grace).toISOString().slice(0,10); }
  function resetAt(now) { return (Math.floor((epoch(now)+offset-grace)/dayMs)+1)*dayMs-offset+grace; }
  function validateLedger(ledger) {
    if (!ledger||ledger.version!==1||!ledger.accounts||typeof ledger.accounts!=='object'||Array.isArray(ledger.accounts)) fail('사용량 기록을 읽지 못했습니다. 요청을 차단했습니다.');
    for (const [key,a] of Object.entries(ledger.accounts)) {
      if (!/^[a-f0-9]{64}$/.test(key)||!a||typeof a.period!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(a.period)||!Number.isFinite(a.lastTrustedMs)||!a.buckets) fail('사용량 기록이 손상돼 요청을 차단했습니다.');
      for (const s of specs) {
        const b=a.buckets[String(s.id)];
        if (!b||!integer(b.used,0,100000000)||typeof b.serverBlocked!=='boolean') fail('사용량 기록이 손상돼 요청을 차단했습니다.');
      }
    }
  }
  function account(input) {
    validateLedger(input.ledger);
    if (!/^[a-f0-9]{64}$/.test(input.keyID||'')) fail('앱키를 등록해 주세요.');
    const now=epoch(input.now), p=period(now), ledger=copy(input.ledger);
    let a=ledger.accounts[input.keyID];
    if (a && (now+5000<a.lastTrustedMs || p<a.period)) fail('기준 시각이 이전으로 바뀌어 요청을 차단했습니다. 서버 시각을 다시 확인해 주세요.');
    if (!a || p>a.period) {
      a={period:p,lastTrustedMs:now,buckets:{}};
      for(const s of specs) a.buckets[String(s.id)]={used:0,serverBlocked:false};
      ledger.accounts[input.keyID]=a;
    }
    a.lastTrustedMs=Math.max(now,a.lastTrustedMs);
    return {ledger,a};
  }
  function snapshots(a,now) {
    return specs.map(s=>{
      const b=a.buckets[String(s.id)], remaining=b.serverBlocked?0:Math.max(0,s.limit-b.used);
      return {id:s.id,label:'경유지 최적화 '+s.id,limit:s.limit,used:b.used,remaining,blocked:remaining===0,serverBlocked:b.serverBlocked,period:a.period,resetAtMillis:resetAt(now)};
    });
  }
  function refresh(input) {
    const {ledger,a}=account(input);
    return {ledger,quotas:snapshots(a,input.now)};
  }
  function reserve(input) {
    if (input.freePlanConfirmed!==true) fail('SK open API에서 Free 상품인지 확인하고 앱 설정에 표시해 주세요.');
    const s=specs.find(s=>s.id===input.apiID);
    if (!s) fail('지원하지 않는 API입니다.');
    const {ledger,a}=account(input), b=a.buckets[String(s.id)];
    if (b.serverBlocked||b.used>=s.limit) fail('무료 한도를 모두 사용했습니다. 다음 초기화까지 새 요청을 보낼 수 없습니다.');
    b.used+=1; // Persist BEFORE sending. Failures and interrupted requests are never refunded.
    return {ledger,quotas:snapshots(a,input.now),reservation:{keyID:input.keyID,period:a.period,apiID:s.id}};
  }
  function reject(input) {
    validateLedger(input.ledger);
    const ledger=copy(input.ledger), r=input.reservation, a=ledger.accounts[r?.keyID];
    // A late reply to yesterday's request must never consume today's allowance.
    if (a&&a.period===r.period&&specs.some(s=>s.id===r.apiID)) a.buckets[String(r.apiID)].serverBlocked=true;
    return {ledger};
  }
  function raiseUsage(input) {
    const {ledger,a}=account(input), s=specs.find(s=>s.id===input.apiID);
    if (!s||!integer(input.used,0,100000000)) fail('사용 횟수를 확인해 주세요.');
    a.buckets[String(s.id)].used=Math.max(a.buckets[String(s.id)].used,input.used);
    return {ledger,quotas:snapshots(a,input.now)};
  }
  function coordinate(value) {
    if (!value||!Number.isFinite(value.longitude)||!Number.isFinite(value.latitude)||value.longitude<124||value.longitude>132||value.latitude<32||value.latitude>40) return null;
    return {longitude:value.longitude,latitude:value.latitude};
  }
  function location(plan,id) {
    const v=id==='depot'?null:id==='destination'?plan.destination:plan.visits.find(v=>v.id===id), access=id==='depot'?plan.originAccess:v?.roadAccess;
    const explicit=coordinate(id==='depot'?plan.tmapOrigin:v?.tmapCoordinate);
    if (explicit) return explicit;
    if (!access?.curbConfirmed||!access.curbPoint?.token) return null;
    const [x,y]=access.curbPoint.token.split(',').slice(0,2).map(Number);
    // Naver saved route tokens use EPSG:3857, never WGS84 by guesswork.
    if (!Number.isFinite(x)||!Number.isFinite(y)||Math.abs(x)<1000000) return null;
    return coordinate({longitude:x/20037508.342789244*180,latitude:Math.atan(Math.sinh(y/6378137))*180/Math.PI});
  }
  function stopInfo(value) {
    if(value?.poiID!=null&&typeof value.poiID!=='string'||value?.detailAddress!=null&&typeof value.detailAddress!=='string')fail('장소 ID와 상세주소는 문자열로 입력해 주세요.');
    const poiID=String(value?.poiID||'').trim(),detailAddress=String(value?.detailAddress||'').trim();
    if(poiID.length>128||/[\s\x00-\x1f]/.test(poiID))fail('티맵 장소 ID는 검색 결과의 ID를 공백 없이 입력해 주세요.');
    if(detailAddress.length>1000||/[\x00-\x1f]/.test(detailAddress))fail('상세주소는 1000자 이하의 한 줄로 입력해 주세요.');
    return {poiID,detailAddress};
  }
  function dateText(date,minute,maxMinute=1439) {
    const t=Date.parse(date+'T00:00:00+09:00');
    if (!Number.isFinite(t)||!/^\d{4}-\d{2}-\d{2}$/.test(date)||new Date(t+offset).toISOString().slice(0,10)!==date||!integer(minute,0,maxMinute)) fail('운행 날짜·시각을 확인해 주세요.');
    return new Date(t+minute*60000+offset).toISOString().slice(0,16).replace(/[-T:]/g,'');
  }
  // Match the planner's inclusive minute windows and half-open avoidance periods.
  // TMAP accepts one wishStartTime/wishEndTime pair per stop, not a list of windows.
  function windowRanges(value,excluded) {
    if (!String(value||'').trim()) return excluded?[]:[[0,4319]];
    const clock=text=>{
      const m=/^(\d{1,2}):(\d{2})$/.exec(text.trim());
      if(!m||+m[1]>71||+m[2]>59)fail('시각은 00:00~71:59 형식이어야 합니다. 다음 날은 24:00 이상으로 입력합니다.');
      return +m[1]*60 + +m[2];
    };
    const ranges=String(value).split(',').map(part=>{
      const pair=part.trim().split(/\s*[-~～–]\s*/);
      if(pair.length!==2)fail('시간 구간은 09:00-11:30,13:00-15:00처럼 입력합니다.');
      const lo=clock(pair[0]),hi=clock(pair[1]);
      if(lo>hi||(excluded&&lo===hi))fail('시간 구간의 끝은 시작보다 늦어야 합니다.');
      return [lo,hi];
    });
    if(excluded)return ranges;
    ranges.sort((a,b)=>a[0]-b[0]||a[1]-b[1]);
    const merged=[];
    for(const range of ranges){
      const last=merged[merged.length-1];
      if(last&&range[0]<=last[1]+1)last[1]=Math.max(last[1],range[1]);
      else merged.push(range.slice());
    }
    return merged;
  }
  function allowedRanges(v,physical=false) {
    let ranges=windowRanges(physical&&v.allowEarlyArrival?'':v.arrivalWindowsText,false);
    for(const [a,b] of windowRanges(v.avoidWindowsText,true)){
      const next=[];
      for(const [lo,hi] of ranges){
        if(hi<a||lo>=b)next.push([lo,hi]);
        else{if(lo<a)next.push([lo,a-1]);if(hi>=b)next.push([b,hi]);}
      }
      ranges=next;
    }
    return ranges;
  }
  function timeInputs(input) {
    const p=input.plan;
    if(!p||!Array.isArray(p.visits))fail('배송계획을 확인해 주세요.');
    const startTime=dateText(p.planDate,p.startMinute),stops=[],notes=[];
    for(const v of p.visits){
      if(!String(v.name||'').trim()||!integer(v.serviceMinutes,0,1440))fail('거래처 이름·체류시간을 확인해 주세요.');
      let ranges;
      try{
        ranges=allowedRanges(v);
        if(!ranges.length)fail('도착 가능 시간과 회피 시간이 모두 겹칩니다.');
      }catch(e){fail(v.name+': '+e.message);}
      const constrained=Boolean(String(v.arrivalWindowsText||'').trim()||String(v.avoidWindowsText||'').trim());
      const wishStartTime=constrained?dateText(p.planDate,ranges[0][0],4319):'';
      const wishEndTime=constrained?dateText(p.planDate,ranges[ranges.length-1][1],4319):'';
      stops.push({id:v.id,name:v.name,wishStartTime,wishEndTime,viaTime:v.serviceMinutes*60,windowCount:constrained?ranges.length:0});
      if(ranges.length>1)notes.push(v.name+': 티맵에는 첫 가능 시각부터 마지막 가능 시각까지 전달합니다. 중간의 불가 시간은 배송계획에서 따로 검증합니다.');
    }
    return {startTime,stops,notes};
  }
  function request(input) {
    const p=input.plan,c=input.options;
    if (!p||!Array.isArray(p.visits)||!String(p.originName||'').trim()||!p.returnToOrigin) fail('티맵으로 계산할 때는 출발지와 최종 도착지를 선택해 주세요.');
    const s=service(p.visits.length), origin=location(p,'depot'),endNodeID=p.destination?'destination':'depot',end=location(p,endNodeID);
    if(!end)fail('최종 도착지의 하역 위치 좌표를 입력해 주세요.');
    if (!origin) fail('출발지의 하역 위치 좌표를 입력해 주세요.');
    if (new Set(p.visits.map(v=>v.id)).size!==p.visits.length||p.visits.some(v=>!v.id||['depot','destination'].includes(v.id))) fail('거래처 식별자가 중복되거나 잘못됐습니다.');
    if (!c||!['0','1','2','3','10'].includes(c.searchOption)) fail('경로 탐색 옵션을 확인해 주세요.');
    const accuracy=c.deliveryAccuracy??'1';
    if(!['1','2','3'].includes(accuracy))fail('배송 결과 정확도 설정을 확인해 주세요.');
    const timing=timeInputs(input);
    const endInfo=stopInfo(p.destination?p.destination.tmapCoordinate:p.tmapOrigin);
    const body={reqCoordType:'WGS84GEO',resCoordType:'WGS84GEO',startName:encodeURIComponent(p.originName),startX:String(origin.longitude),startY:String(origin.latitude),startTime:timing.startTime,endName:encodeURIComponent(p.destination?.name||p.originName),endX:String(end.longitude),endY:String(end.latitude),endPoiId:endInfo.poiID,searchOption:c.searchOption,carType:'1',coordinateFlag:'0',deliveryAccuracy:accuracy,viaPoints:[]};
    if (c.truckRouting) {
      const fields={truckWidth:[100,300],truckHeight:[100,600],truckWeight:[500,600000],truckTotalWeight:[500,600000],truckLength:[200,4000]};
      for(const [field,range] of Object.entries(fields)) {
        if (!integer(c[field],...range)) fail('화물차 폭·높이·길이·적재중량·총중량을 실제 차량 기준으로 입력해 주세요.');
        body[field]=String(c[field]);
      }
      if(c.truckTotalWeight<c.truckWeight) fail('총중량은 적재중량 이상이어야 합니다.');
      body.truckType='1';
    }
    const wireIDs={};
    p.visits.forEach((v,i)=>{
      const coord=location(p,v.id);
      if (!coord) fail(v.name+': 하역 위치 좌표를 입력해 주세요.');
      if (!String(v.name||'').trim()||!integer(v.serviceMinutes,0,1440)) fail('거래처 이름·체류시간을 확인해 주세요.');
      const wire=String(i+1);wireIDs[wire]=v.id;
      const time=timing.stops[i],info=stopInfo({poiID:v.tmapCoordinate?.poiID,detailAddress:v.tmapCoordinate?.detailAddress??v.naverPlace?.requestAddress??v.naverPlace?.roadAddress??v.naverPlace?.address??''});
      body.viaPoints.push({viaPointId:wire,viaPointName:encodeURIComponent(v.name),viaDetailAddress:info.detailAddress,viaX:String(coord.longitude),viaY:String(coord.latitude),viaPoiId:info.poiID,viaTime:time.viaTime,wishStartTime:time.wishStartTime,wishEndTime:time.wishEndTime});
    });
    return {apiID:s.id,url:'https://apis.openapi.sk.com/tmap/routes/routeOptimization'+s.id+'?version=1',body:JSON.stringify(body),wireIDs,endNodeID};
  }
  function number(v,name) {
    if((typeof v!=='number'&&typeof v!=='string')||String(v).trim()===''||!Number.isFinite(Number(v))||Number(v)<0) fail('티맵 응답의 '+name+' 값을 읽지 못했습니다.');
    return Number(v);
  }
  function optionalNumber(v,name,max=100000000) {
    if(v===null||v===undefined||v==='')return null;
    const result=number(v,name);
    if(!integer(result,0,max))fail('티맵 응답의 '+name+' 값이 범위를 벗어납니다.');
    return result;
  }
  function providerTime(value,name) {
    if(value===undefined||value===null||value==='')return {text:'',millis:null};
    const text=String(value);
    if(!/^\d{14}$/.test(text))fail('티맵 응답의 '+name+' 형식이 잘못됐습니다.');
    const iso=text.slice(0,4)+'-'+text.slice(4,6)+'-'+text.slice(6,8)+'T'+text.slice(8,10)+':'+text.slice(10,12)+':'+text.slice(12,14)+'+09:00',millis=Date.parse(iso);
    if(!Number.isFinite(millis)||timeText(millis)!==text)fail('티맵 응답의 '+name+' 날짜·시각이 잘못됐습니다.');
    return {text,millis};
  }
  function timeText(millis) {return new Date(millis+offset).toISOString().slice(0,19).replace(/[-T:]/g,'');}
  function scheduleIssues(row,plan) {
    if(!plan||row.visitID==='depot')return [];
    const v=plan.visits?.find(v=>v.id===row.visitID);
    if(!v)return [];
    const midnight=Date.parse(plan.planDate+'T00:00:00+09:00'),issues=[];
    const inside=(time,ranges)=>{const minute=Math.floor((providerTime(time,'일정 시각').millis-midnight)/60000);return ranges.some(([lo,hi])=>minute>=lo&&minute<=hi);};
    if(row.arriveTime&&!inside(row.arriveTime,allowedRanges(v,true)))issues.push('티맵 도착이 등록한 도착·회피 시간 조건을 벗어납니다.');
    if(row.workStartTime&&!inside(row.workStartTime,allowedRanges(v)))issues.push('티맵 작업 시작이 등록한 가능·회피 시간 조건을 벗어납니다.');
    if(!row.workStartTime)issues.push('작업 시작시각을 확인할 응답 정보가 부족합니다. 배송계획에서 다시 검증하세요.');
    return issues;
  }
  function parse(input) {
    const data=input.response, request=input.request, now=epoch(input.now);
    if (!data||!Array.isArray(data.features)||data.features.length>50000) fail('티맵의 경로 응답 형식을 읽지 못했습니다.');
    const groups=new Map(), starts=[];
    for(const f of data.features) {
      const p=f.properties||{}, g=f.geometry||{}, type=String(p.pointType||'');
      if(type==='S') { if(g.type==='Point') starts.push(p);continue; }
      if(!/^B\d+$/.test(type)&&type!=='E') continue;
      const index=number(p.index,'순번');
      if(!integer(index,1,101)) fail('티맵 방문 순번이 잘못됐습니다.');
      if(!groups.has(index))groups.set(index,{index,type,point:null,lines:[]});
      const group=groups.get(index);
      if(group.type!==type)fail('티맵 방문 순번이 중복됐습니다.');
      if(g.type==='Point') {
        if(group.point)fail('티맵 방문 지점이 중복됐습니다.');
        group.point=p;
        group.coordinate=coordinate({longitude:g.coordinates?.[0],latitude:g.coordinates?.[1]});
        if(!group.coordinate)fail('티맵 도착 지점 좌표가 잘못됐습니다.');
      } else if(g.type==='LineString') {
        if(!Array.isArray(g.coordinates)||g.coordinates.length<2||g.coordinates.length>200000)fail('티맵 경로 좌표가 잘못됐습니다.');
        const path=g.coordinates.map(x=>coordinate({longitude:x?.[0],latitude:x?.[1]}));
        if(path.some(x=>!x)) fail('티맵 경로 좌표가 잘못됐습니다.');
        group.lines.push({properties:p,coordinates:path});
      }
    }
    const n=Object.keys(request.wireIDs).length, ordered=[...groups.values()].sort((a,b)=>a.index-b.index);
    if(ordered.length!==n+1||ordered.some((g,i)=>g.index!==i+1)||ordered[n].type!=='E'||ordered.slice(0,n).some(g=>!/^B\d+$/.test(g.type))) fail('티맵 결과에 배송지 또는 최종 도착 구간이 빠져 있습니다.');
    const body=JSON.parse(request.body),endNodeID=request.endNodeID||'depot',coordinateFor=id=>id===endNodeID&&id!=='depot'?{longitude:Number(body.endX),latitude:Number(body.endY)}:id==='depot'?{longitude:Number(body.startX),latitude:Number(body.startY)}:(()=>{const v=body.viaPoints.find(v=>request.wireIDs[String(v.viaPointId)]===id);return {longitude:Number(v.viaX),latitude:Number(v.viaY)};})();
    const rows=[], legs=[], paths=[], seen=new Set(),warnings=[];let previous='depot',totalSeconds=0,totalDistance=0,knownTollWon=0,unknownTollCount=0;
    for(const group of ordered) {
      if(!group.point||group.lines.length!==1) fail('티맵의 지점별 이동시간·경로를 읽지 못했습니다.');
      const p=group.point,l=group.lines[0],lp=l.properties;
      const id=group.type==='E'?endNodeID:request.wireIDs[String(p.viaPointId)];
      if(!id||(id!=='depot'&&seen.has(id))||String(p.viaPointId||'')!==String(lp.viaPointId||'')) fail('티맵 결과의 배송지 식별자가 일치하지 않습니다.');
      seen.add(id);
      const seconds=number(lp.time,'이동시간'), distance=number(lp.distance,'거리'), fare=optionalNumber(lp.Fare??lp.fare??p.Fare??p.fare,'통행료',10000000);
      if(seconds>172800||distance>5000000||!integer(seconds,0,172800))fail('티맵 이동시간·거리가 범위를 벗어납니다.');
      totalSeconds+=seconds;totalDistance+=distance;
      if(fare===null)unknownTollCount++;else knownTollWon+=fare;
      const leg={id:'tmap-'+now+'-'+group.index,fromID:previous,toID:id,minutes:Math.ceil(seconds/60),source:'tmap',capturedAt:new Date(now).toISOString(),apiExpiresAt:new Date(now+dayMs).toISOString(),distanceMeters:distance,tollWon:fare,vehicleClass:'1종',note:'티맵 최적화 응답의 이동시간. 방향·하역·도로 확인은 별도.',routeLabel:'티맵 최적화'};
      leg.tmapProvider={requestFrom:coordinateFor(previous),requestTo:coordinateFor(id),travelSeconds:seconds,distanceMeters:distance,tollWon:fare,requestedCarType:String(body.carType),geometry:l.coordinates};
      legs.push(leg);paths.push({id:group.index,coordinates:l.coordinates});
      const arrival=providerTime(p.arriveTime??lp.arriveTime,'도착시각'),complete=providerTime(p.completeTime??lp.completeTime,'완료시각');
      if(arrival.millis!==null&&complete.millis!==null&&complete.millis<arrival.millis)fail('티맵 완료시각이 도착시각보다 빠릅니다.');
      const deliverySeconds=optionalNumber(p.deliveryTime??lp.deliveryTime,'작업시간',172800),waitSeconds=optionalNumber(p.waitTime??lp.waitTime,'대기시간',172800);
      let workStartTime='';
      if(arrival.millis!==null&&waitSeconds!==null)workStartTime=timeText(arrival.millis+waitSeconds*1000);
      else if(complete.millis!==null&&deliverySeconds!==null)workStartTime=timeText(complete.millis-deliverySeconds*1000);
      const row={position:group.index,visitID:id,travelSeconds:seconds,distanceMeters:distance,tollWon:fare,coordinate:group.coordinate,arriveTime:arrival.text,completeTime:complete.text,workStartTime,deliverySeconds,waitSeconds,detailAddress:String(p.viaDetailAddress??lp.viaDetailAddress??''),poiID:String(p.poiId??lp.poiId??''),groupKey:String(p.groupKey??lp.groupKey??''),scheduleIssues:[]};
      if(workStartTime&&((arrival.millis!==null&&providerTime(workStartTime,'작업시작').millis<arrival.millis)||(complete.millis!==null&&providerTime(workStartTime,'작업시작').millis>complete.millis))){row.workStartTime='';row.scheduleIssues.push('응답의 대기·작업·완료시각이 서로 맞지 않습니다.');}
      if(arrival.millis!==null&&complete.millis!==null&&deliverySeconds!==null&&waitSeconds!==null&&Math.abs(complete.millis-arrival.millis-(deliverySeconds+waitSeconds)*1000)>1000)row.scheduleIssues.push('도착~완료와 응답의 대기+작업 시간이 다릅니다.');
      row.scheduleIssues.push(...scheduleIssues(row,input.plan));
      warnings.push(...row.scheduleIssues.map(message=>(id==='depot'?'회사 복귀':input.plan?.visits?.find(v=>v.id===id)?.name||'방문 '+group.index)+': '+message));
      rows.push(row);
      previous=id;
    }
    if(seen.size!==n+1)fail('티맵 결과에 배송지가 빠져 있습니다.');
    const props=data.properties||{};
    const providerTotalDistanceMeters=props.totalDistance===undefined||props.totalDistance===null||props.totalDistance===''?null:number(props.totalDistance,'총 거리');
    const providerTotalTravelSeconds=optionalNumber(props.totalTime,'총 경로 소요시간'),providerTotalTollWon=optionalNumber(props.totalFare,'총 통행료');
    if(providerTotalDistanceMeters!==null&&Math.abs(providerTotalDistanceMeters-totalDistance)>Math.max(n+1,1))warnings.push('티맵 총 거리와 구간 거리 합계가 다릅니다.');
    if(providerTotalTravelSeconds!==null&&Math.abs(providerTotalTravelSeconds-totalSeconds)>1)warnings.push('티맵 총 경로 소요시간과 구간 이동시간 합계가 다릅니다.');
    const tollConflict=providerTotalTollWon!==null&&(providerTotalTollWon<knownTollWon||unknownTollCount===0&&providerTotalTollWon!==knownTollWon);
    if(tollConflict)warnings.push('티맵 총 통행료와 구간 통행료 합계가 다릅니다. 합계를 확정하지 않았습니다.');
    const totalTollWon=tollConflict?null:providerTotalTollWon??(unknownTollCount===0?knownTollWon:null);
    const totalDeliverySeconds=rows.slice(0,n).every(r=>r.deliverySeconds!==null)?rows.slice(0,n).reduce((sum,r)=>sum+r.deliverySeconds,0):null;
    const totalWaitSeconds=rows.every(r=>r.waitSeconds!==null)?rows.reduce((sum,r)=>sum+r.waitSeconds,0):null;
    const requestedDepartureTime=String(body.startTime)+'00',reportedDepartureTime=starts.length===1?providerTime(starts[0].completeTime||starts[0].arriveTime,'출발시각').text:'';
    if(reportedDepartureTime&&reportedDepartureTime!==requestedDepartureTime)warnings.push('티맵 응답의 출발시각이 요청한 출발시각과 다릅니다.');
    const returnTime=rows[n].arriveTime||rows[n].completeTime,departure=providerTime(reportedDepartureTime||requestedDepartureTime,'출발시각'),returned=providerTime(returnTime,'복귀시각');
    const elapsedSeconds=returned.millis!==null&&departure.millis!==null&&returned.millis>=departure.millis?(returned.millis-departure.millis)/1000:null;
    return {apiID:request.apiID,fetchedAtMillis:now,expiresAtMillis:now+dayMs,rows,legs,paths,totalTravelSeconds:totalSeconds,totalDistanceMeters:totalDistance,totalTollWon,knownTollWon,unknownTollCount,providerTotalDistanceMeters,providerTotalTravelSeconds,providerTotalTollWon,totalDeliverySeconds,totalWaitSeconds,requestedDepartureTime,reportedDepartureTime,returnTime,elapsedSeconds,warnings};
  }
  function apply(input) {
    const p=copy(input.plan),r=input.route,now=epoch(input.now);
    if(!r||!Number.isFinite(r.expiresAtMillis)||now>=r.expiresAtMillis||now<r.fetchedAtMillis)fail('티맵 결과가 만료됐습니다. 새로 요청해 주세요.');
    const ids=r.rows.filter(v=>p.visits.some(visit=>visit.id===v.visitID)).map(v=>v.visitID),positions=new Map(ids.map((id,i)=>[id,i+1]));
    if(ids.length!==p.visits.length||new Set(ids).size!==ids.length||p.visits.some(v=>!positions.has(v.id)))fail('거래처가 변경됐습니다. 새로 최적화해 주세요.');
    for(const v of p.visits) {
      const pos=positions.get(v.id);
      if(v.fixedPosition&&v.fixedPosition!==pos||pos<v.minPosition||pos>v.maxPosition) fail(v.name+': 티맵 순서가 등록한 방문 순번 조건과 다릅니다.');
      if((v.afterIDs||[]).some(id=>!positions.has(id)||positions.get(id)>=pos)||v.immediatelyAfterID&&positions.get(v.immediatelyAfterID)!==pos-1)fail(v.name+': 티맵 순서가 선후·바로 다음 조건과 다릅니다.');
    }
    // Preserve every user constraint; keep the provider order in a separate, expiring binding.
    p.tmapBinding={visitIDs:ids,legIDs:r.legs.map(l=>l.id),capturedAt:new Date(r.fetchedAtMillis).toISOString(),expiresAt:new Date(r.expiresAtMillis).toISOString()};
    p.legs=p.legs.filter(l=>l.source!=='tmap');
    for(const leg of r.legs) {
      // Keep manual/Naver alternatives. Planner selects only the bound provider leg for this pair.
      p.legs.push(copy(leg));
    }
    return p;
  }
  function errorInfo(input) {
    const e=input.response?.error||input.response||{}, text=String(e.message||e.errorMessage||''),code=String(e.code||e.errorCode||'');
    const quota=input.status===429||/quota|rate.?limit|limit.{0,30}exceed|한도.{0,30}(초과|소진)|허용.{0,20}(초과|소진)|호출.{0,20}초과|요청.{0,20}초과/i.test(text);
    return {quota,message:quota?'티맵 서버가 이용 한도를 제한했습니다. 다음 초기화까지 추가 요청을 차단합니다.':text?'티맵 오류: '+text+(code?' ('+code+')':''):'티맵 요청 실패 (HTTP '+input.status+')'};
  }
  const api={service,refresh,reserve,reject,raiseUsage,timeInputs,request,parse,apply,errorInfo,location,period,resetAt,validateLedger};
  for(const method of ['refresh','reserve','reject','raiseUsage','timeInputs','request','parse','apply','errorInfo'])api[method+'JSON']=text=>{
    try{return JSON.stringify({ok:true,value:api[method](JSON.parse(text))});}catch(e){return JSON.stringify({ok:false,message:e.message});}
  };
  return api;
})();
if(typeof module!=='undefined') module.exports=DeliveryTMap;
