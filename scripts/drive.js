/* Operating guidance from recorded facts and saved public-map evidence.
   No GPS, network calls, inferred deliveries, or automatic cargo changes. */
var DeliveryDrive=(function(){
 'use strict';
 const trip=typeof DeliveryTrip!=='undefined'?DeliveryTrip:require('./trip.js');
 const planner=typeof DeliveryPlanner!=='undefined'?DeliveryPlanner:require('./planner.js');
 const roads=typeof DeliveryRoads!=='undefined'?DeliveryRoads:require('./roads.js');
 const routeUpdate=typeof DeliveryRouteUpdate!=='undefined'?DeliveryRouteUpdate:require('./route_update.js');
 const copy=x=>JSON.parse(JSON.stringify(x)),fail=s=>{throw Error(s);};
 const canonical=x=>Array.isArray(x)?x.map(canonical):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().filter(k=>x[k]!=null).map(k=>[k,canonical(x[k])])):x;
 // A cache invalidation checksum, not an authentication or security signature.
 function fingerprint(x){const s=JSON.stringify(canonical(x));let a=2166136261,b=2246822519;for(let i=0;i<s.length;i++){a=Math.imul(a^s.charCodeAt(i),16777619);b=Math.imul(b^s.charCodeAt(i),3266489917);}return s.length+':'+(a>>>0).toString(16)+':'+(b>>>0).toString(16);}
 const basis=t=>fingerprint({id:t.id,plan:t.plan,events:t.events});
 function cached(t){
  if(t.plan?.tmapBinding) {
   const expiry=Date.parse(t.plan.tmapBinding.expiresAt),captured=Date.parse(t.plan.tmapBinding.capturedAt);
   if(!Number.isFinite(expiry)||!Number.isFinite(captured)||Date.now()>=expiry||Date.now()<captured-60000)return null;
  }
  const g=t.guidance;if(g?.schemaVersion!==1||typeof g.resultJSON!=='string'||g.resultJSON.length>16000000)return null;
  try{const r=JSON.parse(g.resultJSON);return g.resultFingerprint===fingerprint(r)&&Array.isArray(r.rows)&&r.rows.length<=30&&Array.isArray(r.messages)?r:null;}catch(_){return null;}
 }
 function saveResult(t,result,message){t.guidance={schemaVersion:1,basis:basis(t),resultJSON:result?JSON.stringify(result):null,resultFingerprint:result?fingerprint(result):'',generatedAt:new Date().toISOString(),message};}
 function refresh(t){
  if(trip.replay(t).state.phase!=='ready')return t;
  try{const r=trip.replan(t);saveResult(t,r,r.status==='candidate'?'실제 기록으로 남은 일정을 계산하고 저장했습니다.':r.messages.join('\n'));}
  catch(e){saveResult(t,null,'실제 기록은 저장했습니다. 남은 일정 계산: '+String(e.message||e));}
  return t;
 }
 function nextLeg(runtime,result){
  const {plan,state:s}=runtime;
  if(s.phase==='driving')return plan.legs.find(l=>l.id===s.transit.legID);
  if(s.phase==='atStop')return plan.legs.find(l=>l.id===s.actualLegIDs[s.actualLegIDs.length-1]&&l.toID===s.currentID);
  if(s.phase!=='ready'||result?.status!=='candidate')return null;
  const id=result.rows[0]?.legID??result.returnLegID;return plan.legs.find(l=>l.id===id&&l.fromID===s.currentID);
 }
 function packet(runtime,leg,result,fresh){
  if(!leg)return null;
  if(leg.source==='tmap'&&(!Number.isFinite(Date.parse(leg.apiExpiresAt))||Date.now()>=Date.parse(leg.apiExpiresAt)))return null;
  const {plan,state:s}=runtime,v=leg.toID==='destination'?plan.destination:plan.visits.find(v=>v.id===leg.toID),access=leg.toID==='depot'?plan.originAccess:v?.roadAccess;
  let capture=null;try{capture=JSON.parse(leg.captureJSON||'null');}catch(_){}
  const sig=roads.routeSignature(capture),page=roads.parseURL(leg.pageURL),saved=roads.parseURL(capture?.pageURL);
  const details=!!sig&&page?.mode==='car'&&JSON.stringify(page.points)===JSON.stringify(saved?.points)&&(page.selectedIndex??0)===(saved.selectedIndex??0);
  const route=details?capture.candidates.find(c=>c.selected):null,evidence=roads.inspect(plan,leg);
  const row=fresh?result?.rows.find(r=>r.visitID===leg.toID):null;
  const departure=s.transit?.startMinute??(fresh?(result.currentDepartureMinute??row?.legDepartureMinute):null);
  return {legID:leg.id,fromID:leg.fromID,toID:leg.toID,destinationName:v?.name||plan.originName,
   routeURL:page?.mode==='car'&&(!capture||details)?leg.pageURL:null,minutes:leg.minutes,distanceMeters:leg.distanceMeters??null,capturedAt:leg.capturedAt||null,
   routeLabel:leg.routeLabel||'',source:leg.source,departureMinute:departure,arrivalMinute:s.phase==='atStop'?s.arrivalMinute:s.transit?s.transit.startMinute+leg.minutes:fresh?(row?.arrivalMinute??result.finishMinute):null,
   serviceStartMinute:row?.serviceStartMinute??null,note:v?.note||'',accessNote:access?.note||'',arrivalWindowsText:v?.arrivalWindowsText||'',avoidWindowsText:v?.avoidWindowsText||'',
   curbName:access?.curbPoint?.name||'',entranceName:access?.entrancePoint?.name||'',directionValidated:evidence.directionValidated,heightValidated:evidence.heightProfileValidated,
   heightMM:evidence.heightProfileValidated?leg.road.heightMM:null,class1TollWon:evidence.class1TollWon,roadConditionsEnabled:!!plan.road?.enabled,
   guides:details?capture.detail.guides.map((g,index)=>({index,type:g.type||'',instruction:g.instruction||'',distanceText:g.distanceText||''})):[],
   sections:(route?.sections||[]).map(g=>({road:g.road||'',congestion:g.congestion||'',distanceText:g.distanceText||'',distanceMeters:g.distanceMeters??null}))};
 }
 function envelope(t){
  const runtime=trip.replay(t),r=trip.report(runtime),result=cached(t),currentBasis=basis(t);
  const fresh=!!result&&t.guidance?.basis===currentBasis,candidate=fresh&&result.status==='candidate';
  const leg=nextLeg(runtime,fresh?result:null),route=packet(runtime,leg,result,fresh);
  const rest=!r.restTaken&&result?.rest&&!r.completedIDs.includes(result.rest.visitID)?result.rest:fresh?result.rest:null;
  const restBeforeDeparture=!!(r.phase==='ready'&&candidate&&!r.restTaken&&rest?.visitID===r.currentID&&rest.endMinute<=(route?.departureMinute??-1));
  const needsRefresh=r.phase==='ready'&&(t.guidance?.basis!==currentBasis||!!t.guidance?.resultJSON&&!result);
  let issue=r.departureIssue;
  if(r.phase==='ready'&&!candidate)issue=needsRefresh?'현재 기록으로 남은 일정을 다시 계산해야 합니다.':t.guidance?.message||'출발할 일정이 없습니다.';
  if(restBeforeDeparture)issue='예정된 휴식을 실제로 마친 뒤 기록해 주세요.';
  const visit=runtime.plan.visits.find(v=>v.id===r.currentID);
  const window=r.phase==='atStop'?planner.allowedWindows(visit).find(([,end])=>end>=r.clock):null;
  const message=r.phase==='ready'?(t.guidance?.basis===currentBasis?t.guidance.message:'실제 기록을 저장했습니다. 남은 일정을 갱신합니다.'):
   r.phase==='driving'?'다음 목적지로 이동 중입니다. 도착한 뒤 실제 도착을 기록해 주세요.':r.phase==='atStop'?'실제 상하차·작업 완료를 기록하면 다음 일정을 계산합니다.':'회사 복귀 기록을 저장했습니다.';
  return {ok:true,errors:[],trip:t,report:r,result:fresh?result:null,drive:{scheduleFresh:fresh,needsRefresh,hasCandidate:candidate,generatedAt:t.guidance?.generatedAt||null,message,
   route,upcoming:(result?.rows||[]).filter(row=>!r.completedIDs.includes(row.visitID)).map(row=>({visitID:row.visitID,position:row.position,arrivalMinute:row.arrivalMinute,readyMinute:row.readyMinute,current:row.visitID===(r.transit?.toID||r.currentID)})),
   finishMinute:fresh?result.finishMinute:null,rest,restBeforeDeparture,workNotBefore:window?Math.max(window[0],r.clock):null,canDepart:r.canDepart&&candidate&&!!route&&!restBeforeDeparture,departureIssue:issue}};
 }
 function create(plan,previous,minute,id){
  if(previous?.status!=='candidate'||!previous.loadingValidated)fail('적재 검증을 통과한 계획을 먼저 계산해 주세요.');
  if(!Number.isSafeInteger(minute)||minute<0||minute>1439)fail('실제 회사 출발 시각을 확인해 주세요.');
  const actual=copy(plan);if(previous.generatedCargo)actual.cargo=copy(previous.generatedCargo);
  if(actual.cargo?.autoLayout)actual.cargo.autoLayout.enabled=false;
  actual.startMinute=minute;actual.originWaitMinutes=0;
  const checked=planner.solve(actual);
  if(checked.status!=='candidate'||!checked.loadingValidated||checked.originDepartureMinute!==minute)fail('실제 출발 시각과 이미 실은 배치로 가능한 일정을 찾지 못했습니다. '+checked.messages.join('\n'));
  const t=trip.create(actual,checked,minute,id).trip;saveResult(t,checked,'실제 회사 출발 시각과 확정한 적재 배치로 계산했습니다.');return envelope(t);
 }
 function depart(t,minute,id){
  const before=envelope(t),d=before.drive,r=before.report;
  if(r.phase!=='ready'||!d.canDepart)fail(d.departureIssue||'작업 완료 후 출발 가능한 일정을 확인해 주세요.');
  const planned=d.route.departureMinute;
  if(minute!==planned)fail(minute<planned?'예정 출발 시각 전입니다. 필요한 대기를 마친 뒤 실제 시각을 기록해 주세요.':'실제 시각까지 대기를 기록하여 일정을 갱신한 뒤 출발해 주세요.');
  const next=trip.apply(t,{id,type:'depart',minute,toID:d.route.toID,legID:d.route.legID}).trip;
  // Exact planned departure preserves this schedule; every other actual event invalidates it.
  next.guidance.basis=basis(next);return envelope(next);
 }
 function record(t,command){
  if(command.type==='depart'){
   const d=envelope(t).drive;if(command.toID!==d.route?.toID||command.legID!==d.route?.legID)fail('현재 계산에서 선택한 다음 경로와 다릅니다.');
   return depart(t,command.minute,command.id);
  }
  return envelope(trip.apply(t,command).trip);
 }
 function apply(t,c){const result=record(t,c);return envelope(refresh(result.trip));}
 function replan(t){if(trip.replay(t).state.phase!=='ready')fail('현재 거래처 작업 완료 후 남은 일정을 계산합니다.');return envelope(refresh(copy(t)));}
 function compare(t,capture){
  const e=envelope(t),leg=trip.replay(t).plan.legs.find(l=>l.id===e.drive.route?.legID);let original=null;try{original=JSON.parse(leg?.captureJSON||'null');}catch(_){}
  const a=roads.routeSignature(original),b=roads.routeSignature(capture);if(!a||!b)fail('저장된 경로와 새로 읽은 자동차 상세 안내가 모두 필요합니다.');
  const first=JSON.parse(a),second=JSON.parse(b),sameStops=JSON.stringify(first.points)===JSON.stringify(second.points),sameGuides=a===b;
  const needed=(t.plan.road?.vehicleHeightMM||0)+(t.plan.road?.clearanceMarginMM||0),observed=capture.observedVehicleSettings;
  const heightConfirmed=observed?.confirmed===true&&/^[2-5]종$/.test(observed.vehicleClass)&&observed.vehicleClass===capture.vehicleClass&&observed.heightMM>=needed&&observed.heightMM>0;
  const messages=[];
  if(!sameStops)messages.push('출발·경유·도착 지점이 달라졌습니다.');
  if(!sameGuides)messages.push('전체 거리 또는 상세 안내가 달라졌습니다. 저장된 높이·방향·1종 요금 확인을 이 경로에 적용할 수 없습니다.');
  else messages.push('지점·전체 거리·상세 안내가 일치합니다. 전체 도로 형상이나 경로 고정을 보증하지는 않습니다.');
  if(t.plan.road?.requireHeight&&!heightConfirmed)messages.push('새로 읽은 화면에서 필요한 차량 높이 설정을 확인하지 못했습니다.');
  return {ok:true,errors:[],comparison:{legID:leg.id,sameStops,sameGuides,heightConfirmed,plannedMinutes:leg.minutes,observedMinutes:capture.candidates.find(c=>c.selected)?.durationMinutes??null,observedAt:capture.capturedAt||null,sourceTimeText:capture.sourceTimeText||'',messages,estimatesApplied:false}};
 }
 function routeDraft(t,id,c){const r=trip.replay(t);return {ok:true,errors:[],routeDraft:{...routeUpdate.prepare(r.plan,r.state,id,c),baseBasis:basis(t)}};}
 function assertDraft(t,d){if(d?.baseBasis!==basis(t))fail('운행 기록이 바뀌었습니다. 새 경로를 다시 가져와 주세요.');}
 function reuseRoute(t,d,confirmed){assertDraft(t,d);const r=trip.replay(t);return {ok:true,errors:[],routeDraft:routeUpdate.reuse(r.plan,r.state,d,confirmed)};}
 function previewRoute(t,d,minute,id){
  assertDraft(t,d);const runtime=trip.replay(t),change=routeUpdate.change(runtime.plan,runtime.state,d);
  const command={id,type:'routeUpdate',minute,routeUpdate:change};
  const proposed=trip.apply(t,command).trip,after=envelope(refresh(proposed)),before=envelope(t);
  const messages=['선택한 경로 후보 1개를 갱신합니다. 나머지 구간은 각 구간의 저장된 이동시간을 사용합니다.'];
  if(d.reusedChecks)messages.push('이전 확인 내용과 연결한 요금은 이전 자료의 판독 시각을 유지합니다.');
  if(!after.drive.hasCandidate)messages.push('새 자료로 조건을 만족하는 일정을 찾지 못했습니다. 반영하면 이전 시간표로 출발하지 못하며 변경한 자료와 실제 기록은 보존됩니다.');
  if(after.result)messages.push(...after.result.messages);else messages.push(after.drive.message);
  return {ok:true,errors:[],routeProposal:{baseBasis:basis(t),event:command,beforeFinishMinute:before.drive.finishMinute,result:after.result,hasCandidate:after.drive.hasCandidate,messages}};
 }
 function commitRoute(t,proposal){
  if(proposal?.baseBasis!==basis(t)||proposal?.event?.type!=='routeUpdate')fail('미리보기 이후 운행 기록이 바뀌었습니다. 다시 계산해 주세요.');
  // Persist this observation first; native storage requests replan after the write succeeds.
  return record(t,proposal.event);
 }
 const safe=fn=>{try{return JSON.stringify(fn());}catch(e){return JSON.stringify({ok:false,errors:[String(e.message||e)]});}};
 return {basis,cached,envelope,create,record,apply,replan,depart,compare,routeDraft,reuseRoute,previewRoute,commitRoute,
  createJSON:(p,r,m,id)=>safe(()=>create(JSON.parse(p),JSON.parse(r),m,id)),
  recordJSON:(t,c)=>safe(()=>record(JSON.parse(t),JSON.parse(c))),applyJSON:(t,c)=>safe(()=>apply(JSON.parse(t),JSON.parse(c))),
  inspectJSON:t=>safe(()=>envelope(JSON.parse(t))),replanJSON:t=>safe(()=>replan(JSON.parse(t))),
  departJSON:(t,m,id)=>safe(()=>depart(JSON.parse(t),m,id)),compareJSON:(t,c)=>safe(()=>compare(JSON.parse(t),JSON.parse(c))),
  routeDraftJSON:(t,id,c)=>safe(()=>routeDraft(JSON.parse(t),id,JSON.parse(c))),reuseRouteJSON:(t,d,confirmed)=>safe(()=>reuseRoute(JSON.parse(t),JSON.parse(d),confirmed)),
  previewRouteJSON:(t,d,m,id)=>safe(()=>previewRoute(JSON.parse(t),JSON.parse(d),m,id)),commitRouteJSON:(t,p)=>safe(()=>commitRoute(JSON.parse(t),JSON.parse(p)))};
})();
if(typeof module!=='undefined'&&module.exports)module.exports=DeliveryDrive;
