/* Public map-page references and explicit stop/road constraints.
   Map waypoints request a direction; they do not prove road geometry or legality. */
var DeliveryRoads=(function(){
 'use strict';
 const tidy=x=>String(x||'').replace(/\s+/g,' ').trim();
 const copy=x=>JSON.parse(JSON.stringify(x));
 const kinds=['naverMultiLane','twoWayNarrow','oneWay'];
 const int=(x,a,b)=>Number.isSafeInteger(x)&&x>=a&&x<=b;
 function token(raw){
  if(typeof raw!=='string'||raw.length>3000)return null;
  const parts=raw.split(',');if(parts.length!==5||!parts[0]||!parts[1]||!parts[2]||!parts[4])return null;
  if(!parts.slice(0,2).every(p=>/^[A-Za-z0-9_.-]+$/.test(p))||!/^\w*$/.test(parts[3])||!/^\w+$/.test(parts[4]))return null;
  let name;try{name=decodeURIComponent(parts[2]);}catch(_){return null;}
  if(!tidy(name)||/[\u0000-\u001f\u007f/]/.test(name))return null;
  return {token:parts.slice(0,2).concat(encodeURIComponent(name),parts.slice(3)).join(','),name};
 }
 function parseURL(url){
  // Do not depend on the browser URL class: JavaScriptCore has no DOM globals.
  const m=/^https:\/\/map\.naver\.com\/p\/directions\/([^/?#]+)\/([^/?#]+)\/([^/?#]+)\/(car|bike|walk)(?:\/(\d+))?(?:\?[^#]*)?$/.exec(String(url||''));
  if(!m)return null;
  const start=token(m[1]),end=token(m[2]),via=m[3]==='-'?[]:m[3].split(':').map(token);
  if(!start||!end||via.some(x=>!x)||via.length>5)return null;
  return {mode:m[4],points:[start,...via,end],selectedIndex:m[5]===undefined?null:+m[5]};
 }
 function stop(plan,id){return id==='depot'?plan.originAccess:id==='destination'?plan.destination?.roadAccess:plan.visits.find(v=>v.id===id)?.roadAccess;}
 function signature(s){
  if(!s)return 'null';
  const value={roadType:s.roadType,curbConfirmed:s.curbConfirmed===true,curb:token(s.curbPoint?.token)?.token||'',approach:token(s.approachPoint?.token)?.token||'',departure:token(s.departurePoint?.token)?.token||'',entrance:token(s.entrancePoint?.token)?.token||''};
  if(s.bikeEntrance)value.bikeEntrance=[s.bikeEntrance.stopID,s.bikeEntrance.entranceConfirmed===true,s.bikeEntrance.capture?.point?.token,s.bikeEntrance.capture?.routeKey];
  if(s.curbEntranceToken)value.curbEntranceToken=s.curbEntranceToken;
  return JSON.stringify(value);
 }
 function bikeCaptureValid(c){
  const source=parseURL(c?.sourceURL),p=token(c?.point?.token),preview=parseURL(c?.previewURL);
  if(!source||source.mode!=='bike'||source.points.length!==2||!p||c.version!==1||c.method!=='rendered_svg_and_tiles'||!int(c.tileZoom,19,23)||!int(c.guideCount,2,10000))return false;
  if(source.points[0].token!==c.start?.token||source.points[1].token!==c.destination?.token||c.routeKey!==source.points.map(p=>p.token).join('/')+'/bike'||c.selectedIndex!==(source.selectedIndex??0))return false;
  if(!preview||preview.mode!=='bike'||preview.points.length!==2||preview.points[0].token!==source.points[0].token||preview.points[1].token!==p.token)return false;
  if(![c.mercatorX,c.mercatorY,c.latitude,c.longitude,c.screenResolutionMeters,c.destinationGapMeters].every(Number.isFinite)||c.screenResolutionMeters<=0||c.screenResolutionMeters>2||c.destinationGapMeters<0)return false;
  const half=20037508.342789244;
  if(c.longitude<124||c.longitude>132||c.latitude<32||c.latitude>40||Math.abs(c.longitude-c.mercatorX/half*180)>1e-8||Math.abs(c.latitude-Math.atan(Math.sinh(c.mercatorY/6378137))*180/Math.PI)>1e-8)return false;
  const expected=c.mercatorX.toFixed(3)+','+c.mercatorY.toFixed(3)+','+encodeURIComponent(source.points[1].name+' · 자전거 종점')+',,SIMPLE_POI';
  return p.token===expected&&p.name===c.point.name&&c.destination.name===source.points[1].name&&c.start.name===source.points[0].name&&typeof c.capturedAt==='string'&&Number.isFinite(Date.parse(c.capturedAt));
 }
 function entrance(access,capture,stopID,currentURL){
  const live=parseURL(currentURL),source=parseURL(capture?.sourceURL);
  if(!tidy(stopID)||!bikeCaptureValid(capture)||!live||live.mode!=='bike'||live.points.length!==2||live.points.map(p=>p.token).join('/')!==source.points.map(p=>p.token).join('/')||(live.selectedIndex??0)!==capture.selectedIndex)return {ok:false,errors:['현재 자전거 목적지와 읽은 종점이 일치하지 않습니다. 종점을 다시 읽어 주세요.']};
  const next=copy(access||{});
  next.entrancePoint=copy(capture.point);
  next.bikeEntrance={stopID,capture:copy(capture),entranceConfirmed:false};
  next.curbConfirmed=false;next.curbEntranceToken=null;
  return {ok:true,errors:[],access:next};
 }
 function stopErrors(s,name,id){
  const e=[];if(!s||!kinds.includes(s.roadType))e.push(name+': 하역 도로 유형을 선택해 주세요.');
  if(!s||!token(s.curbPoint?.token))e.push(name+': 실제 차량 하역 지점을 지도에서 지정해 주세요.');
  if(s&&s.curbConfirmed!==true)e.push(name+': 차량이 실제로 멈출 하역 위치를 확인해 주세요.');
  if(s?.bikeEntrance){
   const b=s.bikeEntrance;
   if(!bikeCaptureValid(b.capture)||b.stopID!==id||b.capture?.point?.token!==s.entrancePoint?.token)e.push(name+': 자전거 종점과 거래처의 연결 정보가 다릅니다. 입구를 다시 등록해 주세요.');
   if(b.entranceConfirmed!==true)e.push(name+': 자전거 종점이 이 거래처의 실제 입구인지 확인해 주세요.');
   if(s.curbEntranceToken!==s.entrancePoint?.token)e.push(name+': 현재 입구 앞의 차량 하역 위치를 다시 연결해 주세요.');
  }
  if(s?.roadType==='twoWayNarrow'){
   if(!token(s.approachPoint?.token)||!token(s.departurePoint?.token))e.push(name+': 좁은 양방향 도로의 진입·진출 통과 지점을 지정해 주세요.');
   const values=[s.curbPoint,s.approachPoint,s.departurePoint].map(p=>token(p?.token)?.token);
   if(values.every(Boolean)&&new Set(values).size!==3)e.push(name+': 하역 지점과 진입·진출 지점은 서로 달라야 합니다.');
  }
  return e;
 }
 function request(plan,fromID,toID){
  const from=stop(plan,fromID),to=stop(plan,toID),name=id=>id==='depot'?plan.originName:id==='destination'?plan.destination?.name:plan.visits.find(v=>v.id===id)?.name||id;
  const errors=fromID===toID?['서로 다른 출발·도착 거래처를 선택해 주세요.']:stopErrors(from,name(fromID),fromID).concat(stopErrors(to,name(toID),toID));
  if(errors.length)return {ok:false,errors};
  const points=[token(from.curbPoint.token)];
  if(from.roadType==='twoWayNarrow')points.push(token(from.departurePoint.token));
  if(to.roadType==='twoWayNarrow')points.push(token(to.approachPoint.token));
  points.push(token(to.curbPoint.token));
  const via=points.slice(1,-1).map(p=>p.token).join(':')||'-';
  return {ok:true,errors:[],fromID,toID,fromSignature:signature(from),toSignature:signature(to),points,url:'https://map.naver.com/p/directions/'+points[0].token+'/'+points[points.length-1].token+'/'+via+'/car',heightMM:Math.max(0,(plan.road?.vehicleHeightMM||0)+(plan.road?.clearanceMarginMM||0))};
 }
 function selected(c){const x=c?.candidates?.filter(v=>v.selected);return x?.length===1?x[0]:null;}
 function routeSignature(c){
  const s=selected(c),p=parseURL(c?.pageURL);
  if(c?.mode!=='자동차'||!c?.quality?.readyForSummaryImport||!c?.detail?.matchesSelected||!s||!p||p.mode!=='car'||!(s.distanceMeters>0)||!Array.isArray(c.detail.guides)||c.detail.guides.length<2)return '';
  const guides=c.detail.guides.map(g=>[tidy(g.type),tidy(g.instruction),g.distanceMeters??null]);
  const stops=guides.filter(g=>/^(출발지|도착지|경유지\d+)$/.test(g[0]));
  if(stops.length!==p.points.length||stops[0][0]!=='출발지'||stops[stops.length-1][0]!=='도착지'||stops.some((g,i)=>g[1]!==tidy(p.points[i].name)))return '';
  return JSON.stringify({points:p.points.map(x=>x.token),distance:s.distanceMeters,guides});
 }
 function captureFor(leg){try{return JSON.parse(leg.captureJSON||'null');}catch(_){return null;}}
 function pointMatch(req,c){const p=parseURL(c?.pageURL);return req.ok&&p?.mode==='car'&&JSON.stringify(p.points.map(x=>x.token))===JSON.stringify(req.points.map(x=>x.token));}
 function tmapProofSignature(p){
  if(!p)return '';
  return JSON.stringify([[p.requestFrom?.longitude,p.requestFrom?.latitude],[p.requestTo?.longitude,p.requestTo?.latitude],p.travelSeconds,p.distanceMeters,p.tollWon??null,p.requestedCarType,p.geometry?.map(c=>[c.longitude,c.latitude])]);
 }
 function tmapCoordinate(t){
  const parts=String(t||'').split(','),x=Number(parts[0]),y=Number(parts[1]);
  if(!Number.isFinite(x)||!Number.isFinite(y)||Math.abs(x)<1000000)return null;
  return {longitude:x/20037508.342789244*180,latitude:Math.atan(Math.sinh(y/6378137))*180/Math.PI};
 }
 function near(a,b){
  if(!a||!b||![a.longitude,a.latitude,b.longitude,b.latitude].every(Number.isFinite))return false;
  const dy=(a.latitude-b.latitude)*Math.PI/180,dx=(a.longitude-b.longitude)*Math.PI/180*Math.cos((a.latitude+b.latitude)/2*Math.PI/180);
  return Math.hypot(dx,dy)*6371000<=5;
 }
 function tmapConnected(plan,leg){
  const p=leg.tmapProvider,a=stop(plan,leg.fromID),b=stop(plan,leg.toID);
  return !!p&&int(p.travelSeconds,0,172800)&&leg.minutes===Math.ceil(p.travelSeconds/60)&&leg.distanceMeters===p.distanceMeters&&(leg.tollWon??null)===(p.tollWon??null)&&p.requestedCarType==='1'&&leg.vehicleClass==='1종'&&Array.isArray(p.geometry)&&p.geometry.length>=2&&
   p.geometry.every(c=>[c.longitude,c.latitude].every(Number.isFinite)&&c.longitude>=124&&c.longitude<=132&&c.latitude>=32&&c.latitude<=40)&&
   near(p.requestFrom,tmapCoordinate(a?.curbPoint?.token))&&near(p.requestTo,tmapCoordinate(b?.curbPoint?.token));
 }
 function attachTmap(plan,leg){
  const req=request(plan,leg.fromID,leg.toID);
  if(!req.ok||!tmapConnected(plan,leg))return {ok:false,errors:req.errors.length?req.errors:['티맵에 요청한 좌표가 현재 확인한 하역 지점과 다릅니다. 실제 하역 지점을 연결한 뒤 다시 요청해 주세요.']};
  const next=copy(leg),p=leg.tmapProvider,sig=tmapProofSignature(p),fare=int(p.tollWon,0,10000000)?p.tollWon:null;
  next.road={fromSignature:req.fromSignature,toSignature:req.toSignature,routeSignature:sig,departureConfirmed:false,arrivalConfirmed:false,legalDirectionConfirmed:false,heightMM:0,heightBasis:'none',heightConfirmed:false,heightNote:'',class1TollWon:fare,fareSource:fare===null?'none':'tmapClass1',fareRouteSignature:sig,fareCaptureJSON:null};
  return {ok:true,errors:[],leg:next,note:'티맵 실제 경로를 연결했습니다. 하역 방향·통행 방향과 전체 구간의 통과 높이를 확인해 주세요.'};
 }
 function attach(plan,leg){
  if(leg.source==='tmap')return attachTmap(plan,leg);
  const req=request(plan,leg.fromID,leg.toID),c=captureFor(leg),sig=routeSignature(c);
  if(!req.ok||!pointMatch(req,c)||!sig)return {ok:false,errors:req.errors.length?req.errors:['지정한 하역 지점·방향 경유지와 일치하는 자동차 상세 경로를 읽어 주세요.']};
  const next=copy(leg),rawObserved=c.observedVehicleSettings;
  const observed=rawObserved?.confirmed&&rawObserved.heightMM>0&&/^[2-5]종$/.test(rawObserved.vehicleClass)?rawObserved:null;
  next.road={fromSignature:req.fromSignature,toSignature:req.toSignature,routeSignature:sig,heightNote:'',departureConfirmed:false,arrivalConfirmed:false,legalDirectionConfirmed:false,heightMM:observed?.heightMM||0,heightBasis:observed?.confirmed?'naverSetting':'none',heightConfirmed:!!observed?.confirmed,class1TollWon:null,fareSource:'none',fareRouteSignature:'',fareCaptureJSON:null};
  if(c.vehicleClass==='1종'&&Number.isFinite(selected(c)?.tollWon))Object.assign(next.road,{class1TollWon:selected(c).tollWon,fareSource:'naverClass1',fareRouteSignature:sig});
  return {ok:true,errors:[],leg:next};
 }
 function matchFare(leg,c){
  const original=captureFor(leg),a=routeSignature(original),b=routeSignature(c),route=selected(c);
  if(c?.vehicleClass!=='1종'||!Number.isSafeInteger(route?.tollWon)||route.tollWon<0)return {ok:false,errors:['1종 자동차의 통행료가 표시된 상세 경로를 읽어 주세요.']};
  if(!a||a!==b)return {ok:false,errors:['출발·경유·도착 지점, 전체 거리 또는 상세 안내가 달라 1종 요금을 연결하지 않았습니다.']};
  const next=copy(leg);if(!next.road)return {ok:false,errors:['먼저 이 경로를 하역 지점과 연결해 주세요.']};
  Object.assign(next.road,{class1TollWon:route.tollWon,fareSource:'matchingGuides',fareRouteSignature:a,fareCaptureJSON:JSON.stringify(c)});
  return {ok:true,errors:[],leg:next,note:'상세 안내가 일치합니다. 도로의 전체 형상이 같다는 자동 증명은 아니므로 같은 경로인지 확인한 뒤 확정합니다.'};
 }
 function inspectTmap(plan,leg){
  const settings=plan.road||{},req=request(plan,leg.fromID,leg.toID),r=leg.road||{},p=leg.tmapProvider,sig=tmapProofSignature(p),reasons=[];
  const connected=req.ok&&tmapConnected(plan,leg)&&r.fromSignature===req.fromSignature&&r.toSignature===req.toSignature&&r.routeSignature===sig;
  const direction=connected&&r.departureConfirmed===true&&r.arrivalConfirmed===true&&r.legalDirectionConfirmed===true;
  const needed=(settings.vehicleHeightMM||0)+(settings.clearanceMarginMM||0);
  const height=connected&&r.heightBasis==='minimumClearance'&&r.heightConfirmed===true&&tidy(r.heightNote).length>0&&int(r.heightMM,1,20000)&&r.heightMM>=needed;
  const tollValid=connected&&p?.requestedCarType==='1'&&r.fareSource==='tmapClass1'&&int(r.class1TollWon,0,10000000)&&r.class1TollWon===p.tollWon&&r.fareRouteSignature===sig;
  if(!connected)reasons.push('현재 하역 지점·경로와 연결되지 않은 티맵 자료');
  if(settings.requireCurb&&!direction)reasons.push('티맵 경로의 출발·도착 하역 방향과 통행 방향 확인 필요');
  if(settings.requireHeight&&!height)reasons.push('티맵 전체 경로의 최소 통과 높이와 확인 근거 필요');
  if(settings.requireClass1Toll&&!tollValid)reasons.push('이 티맵 경로의 1종 통행료 확인 필요');
  const eligible=!settings.enabled||((!settings.requireCurb||direction)&&(!settings.requireHeight||height)&&(!settings.requireClass1Toll||tollValid));
  return {eligible,reasons:eligible?[]:reasons,directionValidated:direction,heightProfileValidated:height,class1TollValidated:tollValid,class1TollWon:tollValid?r.class1TollWon:null,connected,scope:'tmap_route_and_operator_review'};
 }
 function inspect(plan,leg){
  if(leg.locationInvalidated===true)return {eligible:false,reasons:['하역 위치가 변경돼 이전 경로·이동시간을 다시 확인해야 합니다.'],directionValidated:false,heightProfileValidated:false,class1TollValidated:false,class1TollWon:null,connected:false};
  if(leg.source==='tmap')return inspectTmap(plan,leg);
  const settings=plan.road||{},req=request(plan,leg.fromID,leg.toID),c=captureFor(leg),r=leg.road||{},sig=routeSignature(c),reasons=[];
  const rawRoute=selected(c);
  const summaryMatches=rawRoute&&Number.isFinite(rawRoute.durationMinutes)&&leg.minutes===Math.ceil(rawRoute.durationMinutes)&&leg.distanceMeters===rawRoute.distanceMeters&&leg.vehicleClass===c.vehicleClass;
  const connected=!!summaryMatches&&req.ok&&r.fromSignature===req.fromSignature&&r.toSignature===req.toSignature&&r.routeSignature===sig&&!!sig&&pointMatch(req,c);
  let direction=false;
  if(connected){
   const a=stop(plan,leg.fromID),b=stop(plan,leg.toID),side=c.detail.arrivalSide;
   const departure=a.roadType!=='twoWayNarrow'||r.departureConfirmed===true;
   const arrival=b.roadType==='oneWay'||(side!=='left'&&(b.roadType==='naverMultiLane'||side==='right'||r.arrivalConfirmed===true));
   const legal=(a.roadType!=='twoWayNarrow'&&b.roadType!=='twoWayNarrow')||r.legalDirectionConfirmed===true;
   direction=departure&&arrival&&legal;
   if(!departure)reasons.push('좁은 도로의 출발 방향 확인 필요');
   if(!arrival)reasons.push(side==='left'?'도착지가 반대편인 경로':'하역 지점 도착 방향 확인 필요');
   if(!legal)reasons.push('방향 경유지 전후의 회전·통행 확인 필요');
  }else reasons.push('현재 하역 지점·도로 유형과 연결되지 않은 경로');
  const needed=(settings.vehicleHeightMM||0)+(settings.clearanceMarginMM||0);
  const observed=c?.observedVehicleSettings;
  const heightSource=r.heightBasis==='minimumClearance'?tidy(r.heightNote).length>0:r.heightBasis==='naverSetting'&&observed?.confirmed===true&&observed.heightMM===r.heightMM&&observed.vehicleClass===c.vehicleClass&&/^[2-5]종$/.test(c.vehicleClass);
  const height=connected&&r.heightConfirmed===true&&!!heightSource&&int(r.heightMM,1,20000)&&r.heightMM>=needed;
  let fareCapture=null;try{fareCapture=JSON.parse(r.fareCaptureJSON||'null');}catch(_){}
  const fareProof=r.fareSource==='naverClass1'?c?.vehicleClass==='1종'&&rawRoute.tollWon===r.class1TollWon:r.fareSource==='confirmedSameRoute'&&fareCapture?.vehicleClass==='1종'&&selected(fareCapture)?.tollWon===r.class1TollWon&&routeSignature(fareCapture)===sig;
  const tollValid=connected&&int(r.class1TollWon,0,10000000)&&r.fareRouteSignature===sig&&!!fareProof;
  if(settings.requireHeight&&!height)reasons.push('차량 높이와 여유 높이를 반영한 경로 확인 필요');
  if(settings.requireClass1Toll&&!tollValid)reasons.push('이 경로의 1종 통행료 확인 필요');
  const eligible=!settings.enabled||((!settings.requireCurb||direction)&&(!settings.requireHeight||height)&&(!settings.requireClass1Toll||tollValid));
  return {eligible,reasons:eligible?[]:reasons,directionValidated:direction,heightProfileValidated:height,class1TollValidated:tollValid,class1TollWon:tollValid?r.class1TollWon:null,connected,scope:'registered_stops_and_map_evidence'};
 }
 function validate(plan){
  const r=plan.road;if(!r?.enabled)return [];
  const errors=[];
  if(typeof r.requireCurb!=='boolean'||typeof r.requireHeight!=='boolean'||typeof r.requireClass1Toll!=='boolean')errors.push('도로 조건 적용 항목을 확인해 주세요.');
  if(r.requireHeight&&(!int(r.vehicleHeightMM,1,20000)||!int(r.clearanceMarginMM,0,1000)||r.vehicleHeightMM+r.clearanceMarginMM>20000))errors.push('차량 전체 높이와 높이 여유값을 입력해 주세요.');
  for(const [id,name] of [['depot',plan.originName],...plan.visits.map(v=>[v.id,v.name]),...(plan.destination?[['destination',plan.destination.name]]:[])])errors.push(...stopErrors(stop(plan,id),name,id));
  return [...new Set(errors)];
 }
 return {parseURL,token,request,signature,routeSignature,attach,matchFare,inspect,validate,bikeCaptureValid,entrance,tmapProofSignature,
  entranceJSON:(access,capture,stopID,url)=>JSON.stringify(entrance(JSON.parse(access),JSON.parse(capture),stopID,url)),
  requestJSON:(text,from,to)=>JSON.stringify(request(JSON.parse(text),from,to)),
  attachJSON:(text,leg)=>JSON.stringify(attach(JSON.parse(text),JSON.parse(leg))),
  fareJSON:(leg,c)=>JSON.stringify(matchFare(JSON.parse(leg),JSON.parse(c))),
  inspectJSON:(text,leg)=>JSON.stringify(inspect(JSON.parse(text),JSON.parse(leg))),
  pointJSON:url=>JSON.stringify(parseURL(url))};
})();
if(typeof module!=='undefined'&&module.exports)module.exports=DeliveryRoads;
