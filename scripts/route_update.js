/* Versioned route observations for a stopped, active trip. Never rewrites history. */
var DeliveryRouteUpdate=(function(){
 'use strict';
 const roads=typeof DeliveryRoads!=='undefined'?DeliveryRoads:require('./roads.js');
 const copy=x=>JSON.parse(JSON.stringify(x)),fail=s=>{throw Error(s);};
 const canonical=x=>Array.isArray(x)?x.map(canonical):x&&typeof x==='object'?Object.fromEntries(Object.keys(x).sort().filter(k=>x[k]!=null).map(k=>[k,canonical(x[k])])):x;
 // Cache/change detection only, not a cryptographic signature.
 function fingerprint(x){const s=JSON.stringify(canonical(x));let a=2166136261,b=2246822519;for(let i=0;i<s.length;i++){a=Math.imul(a^s.charCodeAt(i),16777619);b=Math.imul(b^s.charCodeAt(i),3266489917);}return s.length+':'+(a>>>0).toString(16)+':'+(b>>>0).toString(16);}
 function capture(leg){try{return JSON.parse(leg?.captureJSON||'null');}catch(_){return null;}}
 function canChange(state,leg){
  return state.phase==='ready'&&!!leg&&!state.actualLegIDs.includes(leg.id)&&leg.fromID!=='depot'&&
   (leg.fromID===state.currentID||!state.completedIDs.includes(leg.fromID))&&
   (leg.toID==='depot'||leg.toID!==state.currentID&&!state.completedIDs.includes(leg.toID));
 }
 function target(plan,state,id){const leg=plan.legs.find(l=>l.id===id);if(!canChange(state,leg))fail('작업 완료 후 정차 중에 아직 지나지 않은 남은 경로만 갱신할 수 있습니다.');return leg;}
 function signature(leg){return roads.routeSignature(capture(leg));}
 function check(plan,state,leg,requireEligible=true){
  const previous=target(plan,state,leg?.id),c=capture(leg),selected=c?.candidates?.filter(x=>x.selected);
  if(leg.fromID!==previous.fromID||leg.toID!==previous.toID)fail('등록된 경로의 출발·도착 거래처를 바꿀 수 없습니다.');
  if(!roads.routeSignature(c)||selected?.length!==1)fail('선택한 자동차 경로의 전체 상세 안내를 읽어 주세요.');
  const r=selected[0],stamp=Date.parse(c.capturedAt),oldStamp=Date.parse(previous.capturedAt);
  if(!Number.isFinite(stamp)||leg.capturedAt!==c.capturedAt)fail('경로를 읽은 시각을 확인할 수 없습니다.');
  if(Number.isFinite(oldStamp)&&stamp<oldStamp)fail('이미 저장된 경로보다 오래된 판독 자료입니다. 지도에서 다시 읽어 주세요.');
  if(leg.source!=='naver'||leg.pageURL!==c.pageURL||!Number.isSafeInteger(leg.minutes)||leg.minutes<0||leg.minutes>2880||!Number.isFinite(r.durationMinutes)||r.durationMinutes<0||leg.minutes!==Math.ceil(r.durationMinutes)||leg.distanceMeters!==r.distanceMeters||leg.vehicleClass!==c.vehicleClass)fail('경로의 시각·시간·거리·차종·주소가 판독 자료와 다릅니다.');
  const attached=roads.attach(plan,leg);if(!attached.ok)fail(attached.errors.join('\n'));
  const evidence=roads.inspect(plan,leg);
  if(!evidence.connected)fail('현재 거래처의 하역 위치·진입·진출 지점에 연결된 경로가 아닙니다.');
  if(requireEligible&&!evidence.eligible)fail(evidence.reasons.join('\n'));
  return {previous,evidence};
 }
 function prepare(plan,state,id,c){
  const previous=target(plan,state,id),selected=c?.candidates?.filter(x=>x.selected);
  if(!roads.routeSignature(c)||selected?.length!==1)fail('자동차 경로 하나를 선택하고 상세 안내를 읽어 주세요.');
  const r=selected[0];
  const raw={id:previous.id,fromID:previous.fromID,toID:previous.toID,minutes:Math.ceil(r.durationMinutes),source:'naver',capturedAt:c.capturedAt,vehicleClass:c.vehicleClass,distanceMeters:r.distanceMeters,tollWon:r.tollWon??null,arrivalSideText:c.detail.arrivalSideText||'',pageURL:c.pageURL,captureJSON:JSON.stringify(c),note:previous.note||'',routeLabel:r.label||'자동차 경로'};
  const attached=roads.attach(plan,raw);if(!attached.ok)fail(attached.errors.join('\n'));
  const leg=attached.leg;check(plan,state,leg,false);
  const sameGuides=!!signature(previous)&&signature(previous)===signature(leg);
  return {leg,expectedLegFingerprint:fingerprint(previous),previousMinutes:previous.minutes,previousCapturedAt:previous.capturedAt||null,sameGuides,reusedChecks:false};
 }
 function reuse(plan,state,draft,confirmed){
  if(confirmed!==true)fail('지도 선형까지 실제 같은 경로인지 확인해 주세요.');
  const {previous}=check(plan,state,draft.leg,false);
  if(draft.expectedLegFingerprint!==fingerprint(previous))fail('기준 경로가 변경됐습니다. 새 자료를 다시 가져와 주세요.');
  if(!signature(previous)||signature(previous)!==signature(draft.leg))fail('지점·거리·상세 안내가 달라 이전 확인을 연결할 수 없습니다.');
  const prior=roads.inspect(plan,previous),next=copy(draft),r=next.leg.road,p=previous.road||{};
  if(prior.directionValidated){r.departureConfirmed=p.departureConfirmed===true;r.arrivalConfirmed=p.arrivalConfirmed===true;r.legalDirectionConfirmed=p.legalDirectionConfirmed===true;}
  // Naver vehicle settings must come from the NEW height-route capture.
  // Only a manually checked minimum clearance can be carried across a confirmed identical path.
  if(r.heightBasis==='none'&&p.heightBasis==='minimumClearance'&&prior.heightProfileValidated){r.heightBasis=p.heightBasis;r.heightMM=p.heightMM;r.heightNote=p.heightNote;r.heightConfirmed=true;}
  if(!roads.inspect(plan,next.leg).class1TollValidated&&prior.class1TollValidated){
   r.class1TollWon=p.class1TollWon;r.fareSource='confirmedSameRoute';r.fareRouteSignature=signature(next.leg);
   r.fareCaptureJSON=p.fareSource==='naverClass1'?previous.captureJSON:p.fareCaptureJSON;
  }
  next.reusedChecks=true;return next;
 }
 function change(plan,state,draft){
  const {previous}=check(plan,state,draft.leg);
  if(draft.expectedLegFingerprint!==fingerprint(previous))fail('기준 경로가 변경됐습니다. 새 자료를 다시 가져와 주세요.');
  return {expectedLegFingerprint:draft.expectedLegFingerprint,previousMinutes:previous.minutes,leg:copy(draft.leg),reusedChecks:draft.reusedChecks===true};
 }
 function apply(plan,state,update){
  if(!update||!update.leg)fail('경로 갱신 기록이 없습니다.');
  const {previous}=check(plan,state,update.leg);
  if(update.expectedLegFingerprint!==fingerprint(previous)||update.previousMinutes!==previous.minutes)fail('경로 변경 이력의 이전 값이 일치하지 않습니다.');
  plan.legs[plan.legs.findIndex(l=>l.id===previous.id)]=copy(update.leg);
 }
 return {fingerprint,canChange,prepare,reuse,change,apply,check};
})();
if(typeof module!=='undefined'&&module.exports)module.exports=DeliveryRouteUpdate;
