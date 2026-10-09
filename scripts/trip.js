/* Append-only operating records; every physical change is replayed from the loaded plan. */
var DeliveryTrip=(function(){
 'use strict';
 const cargo=typeof DeliveryCargo!=='undefined'?DeliveryCargo:require('./cargo.js');
 const planner=typeof DeliveryPlanner!=='undefined'?DeliveryPlanner:require('./planner.js');
 const roads=typeof DeliveryRoads!=='undefined'?DeliveryRoads:require('./roads.js');
 const routeUpdate=typeof DeliveryRouteUpdate!=='undefined'?DeliveryRouteUpdate:require('./route_update.js');
 const copy=x=>JSON.parse(JSON.stringify(x)),int=(n,a,b)=>Number.isSafeInteger(n)&&n>=a&&n<=b;
 const fail=message=>{throw Error(message);},tidy=s=>String(s||'').trim();
 function replay(trip){
  if(![1,2].includes(trip?.schemaVersion)||!trip.plan||!Array.isArray(trip.events)||!trip.events.length||trip.events.length>2000)fail('운행 기록 형식을 확인해 주세요.');
  const plan=copy(trip.plan);
  if(!tidy(plan.originName)||!Array.isArray(plan.visits)||plan.visits.length<1||plan.visits.length>30)fail('출발·최종 도착와 거래처 목록을 확인해 주세요.');
  // Expired provider estimates cannot guide a new departure, but actual past events must remain replayable.
  const invalid=planner.validate(plan,{historical:true});if(invalid.length)fail(invalid.join('\n'));
  if(!plan.cargo?.enabled||plan.cargo.autoLayout?.enabled)fail('운행은 확정한 적재 배치로 시작해야 합니다.');
  const added=[];
  for(const e of trip.events)if(e.type==='addPosition'){if(!e.column)fail('재배치 자리 정보가 없습니다.');plan.cargo.columns.push(copy(e.column));added.push(e.column.id);}
  const d=cargo.prepare(plan);if(d.errors.length)fail(d.errors.join('\n'));
  const endID=plan.returnToOrigin?(plan.destination?'destination':'depot'):null;
  const visits=new Map(plan.visits.map(v=>[v.id,v])),eventIDs=new Set(),available=new Set(trip.plan.cargo.columns.map(c=>c.id));
  const state={phase:'new',clock:0,currentID:'depot',completedIDs:[],cargoState:d.initial,totals:Object.create(null),targets:Object.create(null),rests:[],warnings:[],originDepartureMinute:null,readyMinute:0,restAfterReady:0,priorityNextID:'',travelMinutes:0,serviceStarts:Object.create(null),actualLegIDs:[],movedUnits:0};
  const quantity=(l,op)=>state.targets[l.id]?.[op]??l.quantity;
  const done=(where,l,op)=>state.totals[where]?.[l.id]?.[op]||0;
  function warn(s){if(!state.warnings.includes(s))state.warnings.push(s);}
  function nextAllowed(id){
   if(id===endID){if(state.completedIDs.length!==plan.visits.length)fail('아직 작업 완료하지 않은 거래처가 있습니다.');return;}
   const v=visits.get(id),rank=state.completedIDs.length+1;if(!v||state.completedIDs.includes(id))fail('다음 거래처를 확인해 주세요.');
   if(state.priorityNextID&&state.priorityNextID!==id)fail('급한 거래처로 지정한 곳을 먼저 방문해야 합니다.');
   if(v.fixedPosition&&v.fixedPosition!==rank||rank<v.minPosition||rank>v.maxPosition||plan.visits.some(x=>x.fixedPosition===rank&&x.id!==id))fail('지정한 고정 순번·순번 범위와 충돌합니다.');
   if(v.afterIDs.some(id=>!state.completedIDs.includes(id))||v.immediatelyAfterID&&v.immediatelyAfterID!==state.currentID||plan.visits.some(x=>x.immediatelyAfterID===state.currentID&&!state.completedIDs.includes(x.id)&&x.id!==id))fail('선행·바로 다음 방문 조건과 충돌합니다.');
  }
  function depart(e){
   const problem=cargo.checkState(d,state.cargoState);if(problem)fail(problem);
   nextAllowed(e.toID);
   const leg=plan.legs.find(l=>l.id===e.legID&&l.fromID===state.currentID&&l.toID===e.toID);if(!leg)fail('현재 장소에서 다음 장소로 가는 경로 후보를 선택해 주세요.');
   const evidence=roads.inspect(plan,leg);if(!evidence.eligible)fail(evidence.reasons.join('\n'));
   state.transit={fromID:state.currentID,toID:e.toID,legID:leg.id,startMinute:e.minute};state.phase='driving';state.actualLegIDs.push(leg.id);
  }
  for(let index=0;index<trip.events.length;index++){
   const e=trip.events[index];
   if(typeof e.id!=='string'||!e.id||eventIDs.has(e.id)||!int(e.minute,0,4319)||index&&e.minute<state.clock)fail('기록 식별자나 시간 순서를 확인해 주세요.');eventIDs.add(e.id);
   if(e.endMinute!==undefined&&(!['work','rest'].includes(e.type)||!int(e.endMinute,e.minute,4319)))fail('작업·휴식 종료시각을 확인해 주세요.');
   if(index===0&&e.type!=='start')fail('첫 기록은 출발지 출발이어야 합니다.');
   if(e.type==='start'){
    if(index!==0||e.minute>1439)fail('출발지 출발 기록이 중복되거나 날짜 범위를 벗어납니다.');state.originDepartureMinute=e.minute;depart(e);
   }else if(e.type==='arrive'){
    if(state.phase!=='driving')fail('이동 중일 때 도착을 기록할 수 있습니다.');
    state.travelMinutes+=e.minute-state.transit.startMinute;state.currentID=state.transit.toID;state.transit=null;
    state.phase=state.currentID===endID?'returned':'atStop';state.arrivalMinute=e.minute;state.readyMinute=e.minute;
    if(state.currentID===endID){
     if(state.originDepartureMinute<660&&e.minute>=780&&!state.rests.some(r=>r.qualifies))warn('최종 도착까지 11~13시에 시작한 연속 60분 휴식이 기록되지 않았습니다.');
    }else{
     const v=visits.get(state.currentID),windows=planner.allowedWindows({arrivalWindowsText:v.allowEarlyArrival?'':v.arrivalWindowsText,avoidWindowsText:v.avoidWindowsText});
     if(!windows.some(([a,b])=>e.minute>=a&&e.minute<=b))warn(v.name+': 실제 도착이 허용 시간·회피 시간 조건을 벗어났습니다.');
     if(state.priorityNextID===v.id)state.priorityNextID='';
    }
   }else if(e.type==='work'){
    if(!['atStop','ready','returned'].includes(state.phase)||!int(e.endMinute,e.minute,4319)||!Array.isArray(e.actions)||!e.actions.length||e.actions.length>600)fail('정차 중의 작업 시작·종료·수량을 확인해 주세요.');
    for(const action of e.actions){
     const lot=d.lots.find(l=>l.id===action.lotID);if(!lot)fail('화물 묶음이 없습니다.');
     if(action.operation!=='relocate'){
      if(state.phase==='ready')fail('상하차 수량을 추가하려면 작업 완료를 다시 열어 주세요.');
      if(state.phase==='returned'){if(action.operation!=='unload')fail('최종 도착 뒤에는 하차만 기록합니다.');}
      else if((action.operation==='load'?lot.loadAt:lot.unloadAt)!==state.currentID)fail('현재 거래처의 상하차 화물을 선택해 주세요.');
     }
     for(const id of [action.columnID||lot.columnID,action.fromColumnID,action.toColumnID].filter(Boolean))if(!available.has(id))fail('아직 등록하지 않은 재배치 자리입니다.');
     state.movedUnits+=action.quantity;if(!int(state.movedUnits,0,40000))fail('한 운행의 화물 이동 기록은 40000개까지 지원합니다.');
     const moved=cargo.move(d,state.cargoState,action,true);if(!moved.ok)fail(moved.reason);state.cargoState=moved.state;
     if(action.operation!=='relocate'){
      state.totals[state.currentID]??=Object.create(null);state.totals[state.currentID][lot.id]??={load:0,unload:0};state.totals[state.currentID][lot.id][action.operation]+=action.quantity;
      if(state.phase!=='returned'&&state.serviceStarts[state.currentID]===undefined){
       state.serviceStarts[state.currentID]=e.minute;const v=visits.get(state.currentID);
       if(!planner.allowedWindows(v).some(([a,b])=>e.minute>=a&&e.minute<=b))warn(v.name+': 실제 작업 시작이 허용 시간 조건을 벗어났습니다.');
      }
     }
    }
    if(state.phase==='ready')state.restAfterReady+=e.endMinute-e.minute;
   }else if(e.type==='complete'){
    if(state.phase!=='atStop')fail('도착한 거래처에서 작업을 완료할 수 있습니다.');
    const differences=d.lots.filter(l=>l.loadAt===state.currentID||l.unloadAt===state.currentID).filter(l=>{const op=l.loadAt===state.currentID?'load':'unload';return done(state.currentID,l,op)!==quantity(l,op);});
    if(differences.length&&!e.allowVariance)fail('주문과 다른 실제 수량을 확인한 뒤 작업 완료를 기록해 주세요.');
    const v=visits.get(state.currentID);if(differences.length)warn(v.name+': 주문과 다른 상하차 수량으로 완료했습니다.');
    state.completedIDs.push(state.currentID);state.phase=(!plan.returnToOrigin&&state.completedIDs.length===plan.visits.length)?'returned':'ready';state.readyMinute=e.minute;state.restAfterReady=0;
   }else if(e.type==='reopen'){
    if(state.phase!=='ready')fail('현재 거래처의 작업 완료만 다시 열 수 있습니다.');state.completedIDs.pop();state.phase='atStop';
   }else if(e.type==='depart'){
    if(state.phase!=='ready')fail('작업 완료를 기록한 뒤 다음 장소로 출발해 주세요.');depart(e);
   }else if(e.type==='rest'){
    if(!['atStop','ready'].includes(state.phase)||!int(e.endMinute,e.minute+1,4319))fail('정차 중 실제 휴식 시간을 입력해 주세요.');
    const v=visits.get(state.currentID),qualifies=e.minute>=660&&e.minute<=780&&e.endMinute-e.minute>=60;
    if(!v.canRestHere)warn(v.name+': 휴식 가능 장소로 등록되지 않은 곳의 실제 휴식 기록입니다.');
    state.rests.push({visitID:state.currentID,startMinute:e.minute,endMinute:e.endMinute,qualifies});
    if(state.phase==='ready')state.restAfterReady+=e.endMinute-e.minute;
   }else if(e.type==='clock'){
    if(!['atStop','ready'].includes(state.phase))fail('정차 중 시각을 갱신할 수 있습니다.');
   }else if(e.type==='urgent'){
    if(!['atStop','ready'].includes(state.phase)||e.toID===state.currentID||state.completedIDs.includes(e.toID)||e.toID&&!visits.has(e.toID))fail('정차 중 남은 거래처를 다음 방문으로 지정해 주세요.');state.priorityNextID=e.toID;
   }else if(e.type==='target'){
    const lot=d.lots.find(l=>l.id===e.lotID);if(!lot||!['load','unload'].includes(e.operation)||!int(e.quantity,0,20000)||!tidy(e.note)||!['atStop','ready'].includes(state.phase))fail('변경할 주문·수량·사유를 확인해 주세요.');
    const where=e.operation==='load'?lot.loadAt:lot.unloadAt;if(where==='depot'||state.completedIDs.includes(where))fail('이미 완료한 주문은 변경하지 않고 실제 기록으로 보존합니다.');
    state.targets[lot.id]??={};state.targets[lot.id][e.operation]=e.quantity;
   }else if(e.type==='addPosition'){
    if(!['atStop','ready'].includes(state.phase)||available.has(e.column.id))fail('정차 중 새로운 빈자리를 추가해 주세요.');available.add(e.column.id);
   }else if(e.type==='routeUpdate'){
    if(trip.schemaVersion!==2)fail('경로 갱신을 포함한 운행 기록의 버전을 확인해 주세요.');
    routeUpdate.apply(plan,state,e.routeUpdate);
   }else fail('지원하지 않는 운행 기록입니다.');
   state.clock=e.endMinute??e.minute;
  }
  d.taskQuantities=copy(state.targets);d.completedIDs=new Set(state.completedIDs);
  const totals=state.cargoState.reduce((s,col)=>s+col.reduce((n,g)=>n+g.quantity,0),0);if(totals>20000)fail('차량 내 화물 기록이 20000개를 넘습니다.');
  return {trip,plan,data:d,state,quantity,done};
 }
 function report(runtime){
  const {plan,data:d,state:s,quantity,done}=runtime;
  let suggested=[],suggestionMessage='',suggestedHandlingMinutes=0;
  if(s.phase==='atStop'){
   const targets=Object.assign(Object.create(null),copy(s.targets));
   for(const l of d.lots)for(const op of ['load','unload'])if((op==='load'?l.loadAt:l.unloadAt)===s.currentID){
    targets[l.id]??={};let left=Math.max(0,quantity(l,op)-done(s.currentID,l,op));
    if(op==='unload')left=Math.min(left,s.cargoState.reduce((sum,col)=>sum+col.filter(g=>g.lot===l.index).reduce((n,g)=>n+g.quantity,0),0));targets[l.id][op]=left;
   }
   const next=cargo.transition(d,s.cargoState,s.currentID,{taskQuantities:targets});
   if(next.ok){suggested=next.actions;suggestedHandlingMinutes=next.extraMinutes||0;}else suggestionMessage=next.reason;
  }
  const variance=[];
  for(const v of plan.visits)for(const l of d.lots)for(const op of ['load','unload'])if((op==='load'?l.loadAt:l.unloadAt)===v.id)variance.push({visitID:v.id,lotID:l.id,kind:l.kind,operation:op,planned:quantity(l,op),original:l.quantity,actual:done(v.id,l,op),complete:s.completedIDs.includes(v.id)});
  const positions=s.cargoState.flatMap((col,i)=>col.map(g=>({lotID:d.lots[g.lot].id,columnID:d.columns[i].id,kind:d.lots[g.lot].kind,quantity:g.quantity,top:col[col.length-1]===g})));
  const condition=cargo.checkState(d,s.cargoState);
  return {phase:s.phase,currentID:s.currentID,clock:s.clock,originDepartureMinute:s.originDepartureMinute,completedIDs:s.completedIDs,transit:s.transit||null,restTaken:s.rests.some(r=>r.qualifies),rests:s.rests,warnings:s.warnings,variance,suggestedActions:suggested,suggestionMessage,suggestedHandlingMinutes,positions,snapshot:cargo.snapshot(d,s.cargoState,s.currentID,[]),cargoConfig:plan.cargo,priorityNextID:s.priorityNextID,canDepart:!condition&&s.phase==='ready',departureIssue:condition||'',travelMinutes:s.travelMinutes};
 }
 function create(plan,result,minute,id){
  if(result?.status!=='candidate'||!result.loadingValidated||!result.rows?.length)fail('적재 조건을 통과한 계산 결과로 운행을 시작해 주세요.');
  const fixed=copy(plan);if(result.generatedCargo)fixed.cargo=copy(result.generatedCargo);
  if(fixed.cargo?.autoLayout)fixed.cargo.autoLayout.enabled=false;
  const first=result.rows[0],legID=first.legID||fixed.legs.find(l=>l.fromID==='depot'&&l.toID===first.visitID)?.id;
  const trip={schemaVersion:1,id,plan:fixed,createdAt:new Date().toISOString(),events:[{id:id+'-start',type:'start',minute,toID:first.visitID,legID}],voidedEvents:[]};
  return {ok:true,trip,report:report(replay(trip)),errors:[]};
 }
 function apply(trip,command){
  const next=copy(trip);replay(next);
  if(command.type==='undo'){
   if(next.events.length<=1)fail('출발지 출발 이후의 마지막 기록만 되돌릴 수 있습니다.');
   next.voidedEvents??=[];next.voidedEvents.push(next.events.pop());if(next.voidedEvents.length>2000)fail('취소 기록 한도에 도달했습니다.');
  }else {next.events.push(copy(command));if(command.type==='routeUpdate')next.schemaVersion=2;}
  return {ok:true,trip:next,report:report(replay(next)),errors:[]};
 }
 function replan(trip){
  const runtime=replay(trip),{plan,data:d,state:s}=runtime;
  if(s.phase!=='ready')fail('현재 거래처 작업을 완료한 뒤 정차 상태에서 남은 일정을 계산해 주세요.');
  const condition=cargo.checkState(d,s.cargoState);if(condition)fail(condition);
  if(s.priorityNextID){const v=plan.visits.find(v=>v.id===s.priorityNextID),rank=s.completedIDs.length+1;if(v.fixedPosition&&v.fixedPosition!==rank)fail('급한 거래처의 기존 고정 순번과 충돌합니다. 원래 조건은 유지했습니다.');v.fixedPosition=rank;}
  const previous=plan.visits.find(v=>v.id===s.currentID),wait=Math.max(0,previous.maxWaitMinutes-Math.max(0,s.clock-s.readyMinute-s.restAfterReady));
  return planner.solve(plan,{resume:{completedIDs:s.completedIDs,fromID:s.currentID,minute:s.clock,originDepartureMinute:s.originDepartureMinute,restTaken:s.rests.some(r=>r.qualifies),waitRemainingMinutes:wait,cargoState:s.cargoState,taskQuantities:s.targets}});
 }
 const safe=fn=>{try{return fn();}catch(e){return {ok:false,errors:[String(e.message||e)]};}};
 return {replay,report,create,apply,replan,
  createJSON:(p,r,minute,id)=>JSON.stringify(safe(()=>create(JSON.parse(p),JSON.parse(r),minute,id))),
  applyJSON:(t,c)=>JSON.stringify(safe(()=>apply(JSON.parse(t),JSON.parse(c)))),
  inspectJSON:t=>JSON.stringify(safe(()=>({ok:true,report:report(replay(JSON.parse(t))),errors:[]}))),
  replanJSON:t=>JSON.stringify(safe(()=>({ok:true,result:replan(JSON.parse(t)),errors:[]})))};
})();
if(typeof module!=='undefined'&&module.exports)module.exports=DeliveryTrip;
