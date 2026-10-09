/* Local scheduling engine. Travel times are registered minute estimates, not live navigation. */
var DeliveryPlanner = (function () {
  'use strict';
  const cargoEngine = typeof DeliveryCargo !== 'undefined' ? DeliveryCargo : require('./cargo.js');
  const automaticEngine = typeof DeliveryAutoCargo !== 'undefined' ? DeliveryAutoCargo : require('./auto_cargo.js');
  const roads = typeof DeliveryRoads !== 'undefined' ? DeliveryRoads : require('./roads.js');
  const H = 4319;
  const key = (a, b) => JSON.stringify([a, b]);
  const int = (n, lo, hi) => Number.isInteger(n) && n >= lo && n <= hi;
  const merge = ranges => {
    const out = [];
    ranges.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    for (const r of ranges) {
      const last = out[out.length - 1];
      if (last && r[0] <= last[1] + 1) last[1] = Math.max(last[1], r[1]);
      else out.push(r.slice());
    }
    return out;
  };
  function clock(s) {
    const m = /^(\d{1,2}):(\d{2})$/.exec(s.trim());
    if (!m || +m[1] > 71 || +m[2] > 59) throw Error('시각은 00:00~71:59 형식이어야 합니다. 다음 날은 24:00 이상으로 입력합니다.');
    return +m[1] * 60 + +m[2];
  }
  function parseWindows(value, excluded) {
    if (!String(value || '').trim()) return excluded ? [] : [[0, H]];
    const ranges = String(value).split(',').map(part => {
      const pair = part.trim().split(/\s*[-~～–]\s*/);
      if (pair.length !== 2) throw Error('시간 구간은 09:00-11:30,13:00-15:00처럼 입력합니다.');
      const a = clock(pair[0]), b = clock(pair[1]);
      if (a > b || (excluded && a === b)) throw Error('시간 구간의 끝은 시작보다 늦어야 합니다.');
      return [a, b];
    });
    return excluded ? ranges : merge(ranges);
  }
  function allowedWindows(v) {
    let result = parseWindows(v.arrivalWindowsText, false);
    for (const [a, b] of parseWindows(v.avoidWindowsText, true)) {
      const next = [];
      for (const [lo, hi] of result) {
        if (hi < a || lo >= b) next.push([lo, hi]);
        else {
          if (lo < a) next.push([lo, a - 1]);
          if (hi >= b) next.push([b, hi]);
        }
      }
      result = next;
    }
    return result;
  }
  function intersect(ranges, windows) {
    const out = [];
    for (const [lo, hi] of ranges) for (const [a, b] of windows) {
      const left = Math.max(lo,a), right = Math.min(hi,b);
      if (left <= right) out.push([left,right]);
    }
    return merge(out);
  }
  const timingKey = t => (t.earlyStart?'early':'late') + (t.restTaken?'Rest':'NoRest');
  const contains = (ranges,t) => ranges.some(([a,b])=>t>=a&&t<=b);
  const earliest = timings => Math.min(...timings.map(t=>t.ranges[0][0]));
  function advance(timings, previous, v, travel, originWait, trace) {
    const grouped = new Map(), links=[];
    for (const t of timings) {
      const wait=previous?previous.maxWaitMinutes:originWait;
      const departures=[];
      const normal=t.ranges.map(([a,b])=>[a,b+wait]);
      if (!previous) {
        const early=intersect(normal,[[0,659]]),late=intersect(normal,[[660,H]]);
        if(early.length)departures.push({ranges:early,earlyStart:true,restTaken:false,restAtPrevious:false});
        if(late.length)departures.push({ranges:late,earlyStart:false,restTaken:false,restAtPrevious:false});
      } else {
        departures.push({ranges:normal,earlyStart:t.earlyStart,restTaken:t.restTaken,restAtPrevious:false});
        if(t.earlyStart&&!t.restTaken&&previous.canRestHere) {
          const ranges=intersect(t.ranges,[[Math.max(0,660-wait),780]])
            .map(([a,b])=>[Math.max(a,660)+60,b+wait+60]);
          if(ranges.length)departures.push({ranges,earlyStart:true,restTaken:true,restAtPrevious:true});
        }
      }
      for(const dep of departures) {
        const arrivals=intersect(dep.ranges.map(([a,b])=>[a+travel,b+travel]),v.physicalWindows);
        if(!arrivals.length)continue;
        for(const restBeforeWork of [false,true]) {
          if(restBeforeWork&&(!v.allowEarlyArrival||!v.canRestHere||dep.restTaken||!dep.earlyStart))continue;
          const physical=restBeforeWork?intersect(arrivals,[[0,780]]):arrivals;
          if(!physical.length)continue;
          let starts=[];
          if(v.allowEarlyArrival) {
            const first=physical[0][0], floor=restBeforeWork?Math.max(first,660)+60:first;
            starts=intersect([[floor,H-v.serviceMinutes]],v.windows);
          } else starts=intersect(physical,v.windows);
          const ready=intersect(starts.map(([a,b])=>[a+v.serviceMinutes,b+v.serviceMinutes]),[[0,H]]);
          if(!ready.length)continue;
          const target={earlyStart:dep.earlyStart,restTaken:dep.restTaken||restBeforeWork,ranges:ready};
          const k=timingKey(target);
          if(!grouped.has(k))grouped.set(k,Object.assign({},target,{ranges:[]}));
          grouped.get(k).ranges.push(...ready);
          if(trace)links.push({previous:t,targetKey:k,ready,physical,restAtPrevious:dep.restAtPrevious,restBeforeWork,wait});
        }
      }
    }
    const result=[...grouped.values()];
    result.forEach(t=>{t.ranges=merge(t.ranges);});
    return {timings:result,links};
  }
  function prepare(plan, validationOptions = {}) {
    const errors = [];
    if (!plan || ![2,3].includes(plan.schemaVersion) || !Array.isArray(plan.visits) || !Array.isArray(plan.legs)) return {errors:['계획 파일의 형식을 확인해 주세요.']};
    const binding=plan.tmapBinding;
    let visits=plan.visits;
    if(binding) {
      const expiry=Date.parse(binding.expiresAt),captured=Date.parse(binding.capturedAt),now=Date.now();
      if(!validationOptions.historical&&(!Number.isFinite(expiry)||!Number.isFinite(captured)||now>=expiry||now<captured-60000||expiry-captured>86400000))errors.push('티맵 경로 유효기간이 끝났습니다. 새로 요청하거나 티맵 순서를 해제해 주세요.');
      const order=binding.visitIDs;
      if(!Array.isArray(order)||order.length!==visits.length||new Set(order).size!==order.length||visits.some(v=>!order.includes(v.id))||!Array.isArray(binding.legIDs))errors.push('티맵 순서와 현재 거래처가 다릅니다. 새로 요청하거나 티맵 순서를 해제해 주세요.');
      else visits=visits.map(v=>{
        const position=order.indexOf(v.id)+1;
        if(v.fixedPosition&&v.fixedPosition!==position)errors.push(v.name+': 티맵 순서와 고정 순번이 다릅니다.');
        return {...v,fixedPosition:position};
      });
    }
    const n = visits.length;
    if (n < 1 || n > 30) errors.push('거래처는 1~30곳이어야 합니다.');
    if (!int(plan.startMinute, 0, 1439) || !int(plan.originWaitMinutes, 0, 1440)) errors.push('출발시각 또는 출발지 추가 대기 한도를 확인해 주세요.');
    if (typeof plan.originName !== 'string' || !plan.originName.trim()) errors.push('출발지 이름을 입력해 주세요.');
    if (typeof plan.returnToOrigin !== 'boolean') errors.push('최종 도착 방식를 확인해 주세요.');
    if(plan.destination && (typeof plan.destination.name!=='string'||!plan.destination.name.trim()||!plan.returnToOrigin))errors.push('최종 도착지 이름과 도착 방식을 확인해 주세요.');
    const date = new Date(String(plan.planDate) + 'T00:00:00Z');
    if (!/^\d{4}-\d{2}-\d{2}$/.test(plan.planDate || '') || isNaN(date.getTime()) || date.toISOString().slice(0,10) !== plan.planDate) errors.push('운행 날짜를 YYYY-MM-DD로 입력해 주세요.');
    const ids = new Map();
    visits.forEach((v, i) => {
      if (typeof v.id !== 'string' || !v.id || ['depot','destination'].includes(v.id) || ids.has(v.id)) errors.push('거래처 식별자가 없거나 중복됩니다.');
      ids.set(v.id, i);
    });
    const fixed = new Map(), next = new Map();
    const nodes = visits.map((v, i) => {
      const name = String(v.name || '').trim() || String(i + 1) + '번 거래처';
      if (!String(v.name || '').trim()) errors.push(name + ': 이름을 입력해 주세요.');
      if (!int(v.serviceMinutes, 0, 1440) || !int(v.maxWaitMinutes, 0, 1440)) errors.push(name + ': 체류·추가 대기는 0~1440분이어야 합니다.');
      if(typeof v.allowEarlyArrival!=='boolean'||typeof v.canRestHere!=='boolean')errors.push(name+': 조기 도착·휴식 가능 여부를 확인해 주세요.');
      if (!int(v.fixedPosition, 0, n) || !int(v.minPosition, 1, 30) || !int(v.maxPosition, 1, 30) || v.minPosition > Math.min(v.maxPosition, n)) errors.push(name + ': 방문 순번 범위를 확인해 주세요.');
      if (v.fixedPosition && (v.fixedPosition < v.minPosition || v.fixedPosition > v.maxPosition)) errors.push(name + ': 고정 순번이 허용 순번 범위를 벗어납니다.');
      if (v.fixedPosition) {
        if (fixed.has(v.fixedPosition)) errors.push(name + ': ' + v.fixedPosition + '번째 고정 조건이 중복됩니다.');
        fixed.set(v.fixedPosition, i);
      }
      const pred = new Set(Array.isArray(v.afterIDs) ? v.afterIDs : []);
      if (!Array.isArray(v.afterIDs)) errors.push(name + ': 선행 거래처 목록 형식이 잘못됐습니다.');
      if (v.immediatelyAfterID) {
        pred.add(v.immediatelyAfterID);
        if (next.has(v.immediatelyAfterID)) errors.push(name + ': 한 거래처 바로 다음에 두 곳을 지정할 수 없습니다.');
        next.set(v.immediatelyAfterID, i);
      }
      let mask = 0;
      for (const p of pred) {
        if (!ids.has(p) || p === v.id) errors.push(name + ': 선행 거래처가 없거나 자기 자신입니다.');
        else mask |= 1 << ids.get(p);
      }
      let windows = [];
      try { windows = allowedWindows(v); if (!windows.length) errors.push(name + ': 도착 가능 시간과 회피 시간이 모두 겹칩니다.'); }
      catch (e) { errors.push(name + ': ' + e.message); }
      if (!Array.isArray(v.orders) || v.orders.some(o => !int(o.deliver,0,100000) || !int(o.pickup,0,100000))) errors.push(name + ': 주문 수량은 0 이상의 정수여야 합니다.');
      let physicalWindows=[];
      try { physicalWindows=v.allowEarlyArrival?allowedWindows({arrivalWindowsText:'',avoidWindowsText:v.avoidWindowsText}):windows; } catch(_) {}
      return Object.assign({}, v, {name, windows, physicalWindows, predMask:mask >>> 0});
    });
    const color = Array(n).fill(0);
    function cycle(i) {
      if (color[i] === 1) return true;
      if (color[i] === 2) return false;
      color[i] = 1;
      for (let j = 0; j < n; j++) if ((nodes[i].predMask & (1 << j)) && cycle(j)) return true;
      color[i] = 2;
      return false;
    }
    if (nodes.some((_, i) => cycle(i))) errors.push('선후·바로 다음 방문 조건이 서로 순환합니다.');
    errors.push(...roads.validate(plan));
    const pairCounts = new Map();
    const legs = new Map(), legByID = new Map(), roadExcluded = [], names = new Map([['depot', plan.originName], ...nodes.map(v => [v.id, v.name]), ...(plan.destination?[['destination',plan.destination.name]]:[])]);
    const boundIDs=new Set(binding?.legIDs||[]),boundPairs=new Set(plan.legs.filter(l=>boundIDs.has(l.id)).map(l=>key(l.fromID,l.toID)));
    if(binding && boundIDs.size!==plan.visits.length+(plan.returnToOrigin?1:0))errors.push('티맵 경로의 회사 복귀 구간이 빠져 있습니다.');
    for (const leg of plan.legs) {
      if(binding && boundPairs.has(key(leg.fromID,leg.toID))&&!boundIDs.has(leg.id))continue;
      if(leg.source==='tmap') {
        const expiry=Date.parse(leg.apiExpiresAt),captured=Date.parse(leg.capturedAt);
        if(!validationOptions.historical&&(!Number.isFinite(expiry)||!Number.isFinite(captured)||Date.now()>=expiry||Date.now()<captured-60000||expiry-captured>86400000))continue;
      }
      if (!names.has(leg.fromID) || !names.has(leg.toID) || leg.fromID === leg.toID || !int(leg.minutes, 0, 2880)) { errors.push('이동 구간의 거래처 또는 이동시간을 확인해 주세요.'); continue; }
      const k = key(leg.fromID, leg.toID);
      if (typeof leg.id !== 'string' || !leg.id || legByID.has(leg.id)) { errors.push('이동 경로 식별자가 없거나 중복됩니다.'); continue; }
      legByID.set(leg.id,leg);
      pairCounts.set(k,(pairCounts.get(k)||0)+1);
      if(pairCounts.get(k)>6)errors.push(names.get(leg.fromID)+' → '+names.get(leg.toID)+': 방향별 경로 후보는 6개까지 등록할 수 있습니다.');
      const check=roads.inspect(plan,leg);
      if(!check.eligible){roadExcluded.push({legID:leg.id,fromID:leg.fromID,toID:leg.toID,reasons:check.reasons});continue;}
      if(!legs.has(k))legs.set(k,[]);
      legs.get(k).push(leg);

    }
    const cargo = errors.length ? {enabled:false,errors:[]} : cargoEngine.prepare(plan);
    return {errors:[...new Set(errors.concat(cargo.errors))], nodes, ids, fixed, next, legs, legByID, roadExcluded, names, n, cargo};
  }
  function schedule(plan, data, path, legIDs, serviceExtras, home, finalTimingKey, finishAtLastStop, returnDeparture, restAfterLast) {
    let timings=data.resume?data.resume.timings:[{earlyStart:false,restTaken:false,ranges:[[plan.startMinute,plan.startMinute]]}],prev=data.resume?.fromID||'depot';
    const routeLegs=[],layers=[];
    path.forEach((index, k) => {
      const v = {...data.nodes[index],serviceMinutes:data.nodes[index].serviceMinutes+(serviceExtras[k]||0)}, leg = data.legByID.get(legIDs[k]);
      const step=advance(timings,k?data.nodes[path[k-1]]:(data.resume?.previous||null),v,leg.minutes,plan.originWaitMinutes,true);
      layers.push(step.links);timings=step.timings;
      routeLegs.push(leg); prev = v.id;
    });
    let time=finishAtLastStop, tk=finalTimingKey, rest=null;
    const rows=Array(path.length);
    for (let k = path.length - 1; k >= 0; k--) {
      const v={...data.nodes[path[k]],serviceMinutes:data.nodes[path[k]].serviceMinutes+(serviceExtras[k]||0)},leg=routeLegs[k],serviceStart=time-v.serviceMinutes;
      let chosen=null;
      for(const link of layers[k]) {
        if(link.targetKey!==tk||!contains(link.ready,time))continue;
        const possible=v.allowEarlyArrival?intersect(link.physical,[[0,serviceStart-(link.restBeforeWork?60:0)]]):intersect(link.physical,[[serviceStart,serviceStart]]);
        if(!possible.length)continue;
        const arrival=possible[0][0],depart=arrival-leg.minutes,restMinutes=link.restAtPrevious?60:0;
        const eligible=intersect(link.previous.ranges,[[depart-link.wait-restMinutes,Math.min(depart-restMinutes,link.restAtPrevious?780:H)]]);
        if(!eligible.length)continue;
        const p=eligible[0][0];
        if(link.restAtPrevious && Math.max(p,660)+60>depart)continue;
        if(link.restBeforeWork && Math.max(arrival,660)+60>serviceStart)continue;
        chosen={link,arrival,depart,p,restMinutes};break;
      }
      if(!chosen)throw Error('일정 복원에 실패했습니다.');
      const {link,arrival,depart,p,restMinutes}=chosen;
      rows[k]={handlingMinutes:serviceExtras[k]||0,position:k+1+(data.resume?.completedIDs.length||0),visitID:v.id,legID:leg.id,fromID:leg.fromID,travelMinutes:leg.minutes,legDepartureMinute:depart,waitBeforeLeg:depart-p-restMinutes,arrivalMinute:arrival,serviceStartMinute:serviceStart,waitBeforeService:serviceStart-arrival,restBeforeService:link.restBeforeWork,readyMinute:time,departureMinute:time,waitAfterService:0,restMinutesBeforeLeg:restMinutes,restMinutesAfterService:0};
      if(link.restAtPrevious)rest={visitID:leg.fromID,startMinute:Math.max(p,660),endMinute:Math.max(p,660)+60,phase:'afterService'};
      if(link.restBeforeWork)rest={visitID:v.id,startMinute:Math.max(arrival,660),endMinute:Math.max(arrival,660)+60,phase:'beforeService'};
      time=p;tk=timingKey(link.previous);
    }
    for (let k=0; k<rows.length-1; k++) {
      rows[k].departureMinute = rows[k+1].legDepartureMinute;
      rows[k].waitAfterService = rows[k+1].waitBeforeLeg;
      rows[k].restMinutesAfterService=rows[k+1].restMinutesBeforeLeg;
    }
    let returnMinutes = 0;
    if (plan.returnToOrigin) returnMinutes = home.minutes;
    const last=rows[rows.length-1];
    last.departureMinute=returnDeparture;
    last.waitAfterService=returnDeparture-finishAtLastStop-(restAfterLast?60:0);
    last.restMinutesAfterService=restAfterLast?60:0;
    if(restAfterLast)rest={visitID:last.visitID,startMinute:Math.max(finishAtLastStop,660),endMinute:Math.max(finishAtLastStop,660)+60,phase:'afterService'};
    return {rows,rest,lastWorkFinishMinute:finishAtLastStop,originDepartureMinute:rows[0].legDepartureMinute,finishMinute:returnDeparture+returnMinutes,returnMinutes,returnLegID:home?home.id:null};
  }
  function returnOnly(plan,data,base){
    const r=data.resume;
    if(!plan.returnToOrigin)return {...base,status:'candidate',messages:['마지막 배송지의 작업이 완료됐습니다.'],rows:[],searchComplete:true,completedDepth:data.n,remainingFromID:r.fromID,replannedAtMinute:r.minute,originDepartureMinute:r.originDepartureMinute,finishMinute:r.minute,currentDepartureMinute:r.minute,lastWorkFinishMinute:r.minute,returnMinutes:0,totalTravelMinutes:0,loadingValidated:data.cargo.enabled,cargo:cargoEngine.trace(data.cargo,[],r.cargoState,r.fromID)};
    const choices=data.legs.get(key(r.fromID,plan.destination?'destination':'depot'))||[],previous=r.previous;
    let best=null;
    for(const leg of choices){
      const endings=[{departure:r.minute,rest:null}];
      if(r.originDepartureMinute<660&&!r.restTaken&&previous?.canRestHere&&r.minute<=780&&Math.max(r.minute,660)-r.minute<=r.waitRemainingMinutes){
        const start=Math.max(r.minute,660);endings.push({departure:start+60,rest:{visitID:r.fromID,startMinute:start,endMinute:start+60,phase:'afterService'}});
      }
      for(const end of endings){
        const finish=end.departure+leg.minutes;
        if(finish>H||(r.originDepartureMinute<660&&finish>=780&&!r.restTaken&&!end.rest))continue;
        if(!best||finish<best.finish||finish===best.finish&&leg.minutes<best.leg.minutes)best={...end,finish,leg};
      }
    }
    const result={...base,status:best?'candidate':'no_registered_solution',messages:[best?'현재 적재 상태를 유지한 회사 복귀 일정입니다.':'현재 위치에서 회사로 복귀할 경로·필요한 휴식 조건을 만족하지 못했습니다.'],rows:[],searchComplete:true,completedDepth:data.n,roadExcluded:data.roadExcluded,remainingFromID:r.fromID,replannedAtMinute:r.minute,originDepartureMinute:r.originDepartureMinute};
    if(best){
      const e=roads.inspect(plan,best.leg);
      Object.assign(result,{finishMinute:best.finish,currentDepartureMinute:best.departure,lastWorkFinishMinute:r.minute,returnMinutes:best.leg.minutes,returnLegID:best.leg.id,totalTravelMinutes:best.leg.minutes,rest:best.rest,loadingValidated:data.cargo.enabled,cargo:cargoEngine.trace(data.cargo,[],r.cargoState,r.fromID),roadEvidenceValidated:!!plan.road?.enabled&&e.eligible,heightProfileValidated:e.heightProfileValidated,class1TollValidated:e.class1TollValidated,totalClass1TollWon:e.class1TollWon,selectedRoadEvidence:[{legID:best.leg.id,...e}]});
    }
    return result;
  }
  function solve(plan, options) {
    if(!options?.resume&&plan?.cargo?.enabled && plan.cargo.autoLayout?.enabled)return automaticEngine.solve(plan,options,solve);
    const began = Date.now(), opt = options || {}, data = prepare(plan);
    const base = {engineVersion:'0.6.0', status:'invalid', messages:data.errors, rows:[],rest:null,lastWorkFinishMinute:null, finishMinute:null, originDepartureMinute:null, returnMinutes:0, totalTravelMinutes:0, expanded:0, pruned:false, completedDepth:0, elapsedMilliseconds:0, searchComplete:false, loadingValidated:false, cargo:null, generatedCargo:null, automaticLoading:null, cargoRejected:0, cargoSearchLimited:false, roadDirectionValidated:false, roadEvidenceValidated:false, heightProfileValidated:false, class1TollValidated:false, totalClass1TollWon:null, roadExcluded:[], selectedRoadEvidence:[], liveTrafficValidated:false, globalRoadOptimalityProven:false};
    if (data.errors.length) return base;
    if(opt.resume){
      const r=opt.resume;
      const ids=Array.isArray(r.completedIDs)?r.completedIDs:[];
      if(!Array.isArray(r.completedIDs)||ids.length>data.n||new Set(ids).size!==ids.length||ids.some(id=>!data.ids.has(id))||r.fromID!==(ids[ids.length-1]||'depot')||!int(r.minute,0,H)||!int(r.originDepartureMinute,0,r.minute)||typeof r.restTaken!=='boolean'||!int(r.waitRemainingMinutes,0,1440))return {...base,messages:['재계산할 현재 위치·시각·완료 거래처를 확인해 주세요.']};
      if(data.cargo.enabled){
        if(!Array.isArray(r.cargoState)||r.cargoState.length!==data.cargo.columns.length||r.cargoState.some((col,i)=>!Array.isArray(col)||col.some(g=>!int(g.lot,0,data.cargo.lots.length-1)||!cargoEngine.compatible(data.cargo.columns[i],data.cargo.lots[g.lot].kind)||!int(g.quantity,1,20000))))return {...base,messages:['현재 적재 기록을 확인해 주세요.']};
        const failure=cargoEngine.checkState(data.cargo,r.cargoState);if(failure)return {...base,messages:[failure]};
        data.cargo.taskQuantities=r.taskQuantities||{};data.cargo.completedIDs=new Set(ids);
        for(const [id,q] of Object.entries(data.cargo.taskQuantities))if(!data.cargo.lots.some(l=>l.id===id)||Object.entries(q).some(([op,n])=>!['load','unload'].includes(op)||!int(n,0,20000)))return {...base,messages:['남은 주문 수량을 확인해 주세요.']};
      }
      const previous=ids.length?{...data.nodes[data.ids.get(r.fromID)],maxWaitMinutes:r.waitRemainingMinutes}:null;
      data.resume={...r,previous,timings:[{earlyStart:r.originDepartureMinute<660,restTaken:r.restTaken,ranges:[[r.minute,r.minute]]}]};
      if(ids.length===data.n)return returnOnly(plan,data,base);
    }
    const {nodes,n,legs,fixed,next} = data;
    const width = opt.width || (n <= 7 ? 6000 : 400);
    const maxMs = opt.maxMilliseconds || 10000, maxExpanded = opt.maxExpanded || 1200000;
    const missing = new Set(),cargoReasons=new Set();
    const alternatives=new Map(),alternativeLimit=Math.min(16,Math.max(0,opt.candidateLimit||0));
    let cargoRejected=0,cargoSearchLimited=!!(data.cargo.enabled&&data.cargo.config.rehandling?.enabled);
    let frontier = [{mask:data.resume?data.resume.completedIDs.reduce((mask,id)=>mask|(1<<data.ids.get(id)),0)>>>0:0,last:data.resume?.fromID||'depot',path:[],legIDs:[],serviceExtras:[],cargo:data.resume?.cargoState||data.cargo.initial,timings:data.resume?.timings||[{earlyStart:false,restTaken:false,ranges:[[plan.startMinute,plan.startMinute]]}],drive:0,score:data.resume?.minute??plan.startMinute}];
    let expanded = 0, pruned = false, aborted = false, best = null, completedDepth=0;
    const minIncoming = nodes.map(v => {
      let minimum = Infinity;
      for (const leg of [...legs.values()].flat()) if (leg.toID === v.id) minimum = Math.min(minimum,leg.minutes);
      return minimum;
    });
    let minReturn = 0;
    if (plan.returnToOrigin) {
      minReturn = Infinity;
      for (const leg of [...legs.values()].flat()) if (leg.toID === (plan.destination?'destination':'depot')) minReturn = Math.min(minReturn,leg.minutes);
    }
    const bound = state => {
      let value = earliest(state.timings) + minReturn;
      for (let i=0;i<n;i++) if (!(state.mask & (1<<i))) value += nodes[i].serviceMinutes + minIncoming[i];
      return value;
    };
    outer: for (let rank=(data.resume?.completedIDs.length||0)+1;rank<=n;rank++) {
      let generated = [];
      for (const state of frontier) {
        if (++expanded > maxExpanded || Date.now()-began > maxMs) { aborted=true; break outer; }
        const forced = next.get(state.last);
        for (let i=0;i<n;i++) {
          if(Date.now()-began>maxMs){aborted=true;break outer;}
          const v = nodes[i], bit = (1<<i) >>> 0;
          if (state.mask & bit) continue;
          if (fixed.has(rank) && fixed.get(rank)!==i) continue;
          if (forced!==undefined && forced!==i) continue;
          if (v.fixedPosition && v.fixedPosition!==rank) continue;
          if (rank<v.minPosition || rank>v.maxPosition || (state.mask & v.predMask)!==v.predMask) continue;
          if (v.immediatelyAfterID && v.immediatelyAfterID!==state.last) continue;
          const choices = legs.get(key(state.last,v.id));
          if (!choices?.length) { missing.add(key(state.last,v.id)); continue; }
          for(const leg of choices) {
          const previous=state.path.length?nodes[state.path[state.path.length-1]]:(data.resume?.previous||null);
          const work=cargoEngine.transition(data.cargo,state.cargo,v.id,opt.cargoOptions);
          if(!work.ok){cargoRejected++;cargoSearchLimited=cargoSearchLimited||work.limited;if(cargoReasons.size<6)cargoReasons.add(v.name+': '+work.reason);continue;}
          if(work.limited)cargoSearchLimited=true;
          const timings=advance(state.timings,previous,{...v,serviceMinutes:v.serviceMinutes+(work.extraMinutes||0)},leg.minutes,plan.originWaitMinutes,false).timings;
          if(!timings.length)continue;
          const candidate = {mask:(state.mask|bit)>>>0,last:v.id,path:state.path.concat(i),legIDs:state.legIDs.concat(leg.id),serviceExtras:state.serviceExtras.concat(work.extraMinutes||0),cargo:work.state,timings,drive:state.drive+leg.minutes,score:0};
          let possible = true;
          for (let j=0;j<n;j++) if (!(candidate.mask & (1<<j))) {
            const u = nodes[j];
            if (u.maxPosition<=rank || (u.fixedPosition && u.fixedPosition<=rank) || (earliest(timings) > u.windows[u.windows.length-1][1])) { possible=false; break; }
          }
          if (!possible) continue;
          if (rank===n) {
            const homes=plan.returnToOrigin?legs.get(key(v.id,plan.destination?'destination':'depot')):[null];
            if(!homes?.length){missing.add(key(v.id,plan.destination?'destination':'depot'));continue;}
            for(const home of homes){
            const returnMinutes=home?home.minutes:0,drive=candidate.drive+returnMinutes;
            for(const timing of timings) {
              const endings=[{lastReady:timing.ranges[0][0],depart:timing.ranges[0][0],restAfterLast:false}];
              if(timing.earlyStart&&!timing.restTaken&&v.canRestHere) {
                const eligible=intersect(timing.ranges,[[Math.max(0,660-v.maxWaitMinutes),780]]);
                if(eligible.length) {
                  const ready=eligible[0][0];
                  endings.push({lastReady:ready,depart:Math.max(ready,660)+60,restAfterLast:true});
                }
              }
              for(const ending of endings) {
                const finish=ending.depart+returnMinutes;
                if(finish>H || (timing.earlyStart&&finish>=780&&!timing.restTaken&&!ending.restAfterLast))continue;
                if(alternativeLimit){
                  const k=candidate.path.join(',');const old=alternatives.get(k);
                  if(!old||finish<old.finishMinute)alternatives.set(k,{visitIDs:candidate.path.map(index=>nodes[index].id),finishMinute:finish,totalTravelMinutes:drive});
                  if(alternatives.size>alternativeLimit){const worst=[...alternatives.entries()].sort((a,b)=>b[1].finishMinute-a[1].finishMinute||b[1].totalTravelMinutes-a[1].totalTravelMinutes)[0];alternatives.delete(worst[0]);}
                }
                if (!best || finish<best.finish || (finish===best.finish && drive<best.drive)) best={state:candidate,home,finish,drive,lastReady:ending.lastReady,returnDeparture:ending.depart,restAfterLast:ending.restAfterLast,timingKey:timingKey(timing)};
              }
            }
            }
          } else {
            candidate.score=bound(candidate);
            generated.push(candidate);
          }
          }
        }
      }
      completedDepth=rank;
      if (rank===n) break;
      generated.sort((a,b)=>a.score-b.score || earliest(a.timings)-earliest(b.timings) || a.drive-b.drive);
      if (generated.length>width) { generated.length=width; pruned=true; }
      frontier=generated;
      if (!frontier.length) break;
    }
    const messages = [];
    if (best) messages.push(data.cargo.enabled?'등록한 적재 배치에서 상하차·계란 지지 조건을 만족한 방문 순서 후보입니다.':'등록한 경로 후보의 이동시간을 고정값으로 사용한 방문 순서 후보입니다.');
    else messages.push(aborted || pruned ? '탐색 범위 안에서 완성된 순서를 찾지 못했습니다. 조건 불가능을 뜻하지 않습니다.' : '등록한 구간과 시간·순서 조건 안에서 완성된 순서를 찾지 못했습니다.');
    if(data.roadExcluded.length)messages.push('도로 조건으로 경로 후보 '+data.roadExcluded.length+'개를 제외했습니다. 하역·도로 화면에서 근거를 보완할 수 있습니다.');
    if (missing.size) {
      const pairs=[...missing].slice(0,8).map(s=>{const [a,b]=JSON.parse(s);return data.names.get(a)+' → '+data.names.get(b);});
      messages.push('이동시간 미등록으로 탐색에서 제외한 구간 '+missing.size+'개: '+pairs.join(', ')+(missing.size>8?' 외':''));
    }
    if(cargoRejected)messages.push('적재 조건으로 제외한 다음 방문 후보 '+cargoRejected+'건. '+[...cargoReasons].join(' / '));
    if(data.cargo.enabled)messages.push('적재 위치·쌓임·통로·지지 설정을 기준으로 계산했습니다. 재배치를 켜면 등록한 자리 사이의 이동과 추가 작업시간도 반영합니다. 임의의 공간 배치·실차 안정성·총중량 검증은 포함하지 않습니다.');
    if(cargoSearchLimited)messages.push('상하차·재배치는 제한된 작업 순서를 탐색하며 가능한 모든 중간 배치를 비교하지 않습니다. 다른 배치로 더 좋은 순서가 가능한지는 미확인입니다.');
    if (pruned || aborted || cargoSearchLimited) messages.push('계산량 제한을 적용했습니다. 가장 좋은 순서라는 보장은 없습니다.');
    else if (best) messages.push('등록된 구간·분 단위 고정 이동시간 범위에서는 가장 이른 완료시각을 확인했습니다.');
    if(!best)messages.push('오전 11시 전 회사 출발·회사 복귀가 13시 이후라면 11~14시 중 연속 60분을 쉴 수 있는 거래처가 필요합니다. 휴식 시작은 11~13시입니다.');
    const result=Object.assign(base,{status:best?'candidate':(aborted || pruned || cargoSearchLimited?'not_found':'no_registered_solution'),messages,roadExcluded:data.roadExcluded,expanded,pruned,completedDepth,cargoRejected,cargoSearchLimited,elapsedMilliseconds:Date.now()-began,searchComplete:!pruned&&!aborted&&!cargoSearchLimited});
    if(best) Object.assign(result,schedule(plan,data,best.state.path,best.state.legIDs,best.state.serviceExtras,best.home,best.timingKey,best.lastReady,best.returnDeparture,best.restAfterLast),{totalTravelMinutes:best.drive});
    if(best){
      const used=best.state.legIDs.map(id=>data.legByID.get(id)).concat(best.home?[best.home]:[]);
      const evidence=used.map(leg=>({legID:leg.id,...roads.inspect(plan,leg)}));
      result.selectedRoadEvidence=evidence;
      result.roadEvidenceValidated=!!plan.road?.enabled&&evidence.every(e=>e.eligible);
      result.heightProfileValidated=evidence.every(e=>e.heightProfileValidated);
      result.class1TollValidated=evidence.every(e=>e.class1TollValidated);
      result.totalClass1TollWon=result.class1TollValidated?evidence.reduce((sum,e)=>sum+e.class1TollWon,0):null;
      // Registered points, map settings and operator review do not prove full road geometry.
      result.messages.push(result.roadEvidenceValidated?'선택한 도로 조건의 등록 근거를 충족했습니다. 실제 전체 도로 형상의 자동 검증은 아닙니다.':'도로 조건 전체가 검증된 결과는 아닙니다.');
    }
    if(best&&data.cargo.enabled){result.cargo=cargoEngine.trace(data.cargo,best.state.path.map(i=>nodes[i].id),data.resume?.cargoState,data.resume?.fromID);result.loadingValidated=true;}
    if(data.resume){
      result.remainingFromID=data.resume.fromID;result.replannedAtMinute=data.resume.minute;
      result.currentDepartureMinute=result.rows[0]?.legDepartureMinute??null;
      result.originDepartureMinute=data.resume.originDepartureMinute;
      result.messages.push('기록한 현재 위치·시각·화물의 쌓임에서 남은 방문을 계산했습니다. 완료 방문의 순번과 이미 한 휴식을 유지합니다.');
    }
    if(alternativeLimit)result.routeAlternatives=[...alternatives.values()].sort((a,b)=>a.finishMinute-b.finishMinute||a.totalTravelMinutes-b.totalTravelMinutes);
    return result;
  }
  return {validate:(plan,options)=>prepare(plan,options).errors, solve, solveJSON: text => JSON.stringify(solve(JSON.parse(text))), parseWindows, allowedWindows};
})();
if (typeof module !== 'undefined' && module.exports) module.exports = DeliveryPlanner;
