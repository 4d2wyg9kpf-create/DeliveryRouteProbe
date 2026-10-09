/* Bounded joint search: route seeds -> geometry/lot candidates -> full work replay.
   A failed pattern is not a proof that every physical loading arrangement fails. */
var DeliveryAutoCargo = (function () {
  'use strict';
  const cargo=typeof DeliveryCargo!=='undefined'?DeliveryCargo:require('./cargo.js');
  const EPS=0.000001,copy=x=>JSON.parse(JSON.stringify(x));
  const isBag=k=>k.startsWith('rice')||k==='bag25to40';
  const caps={rice20:5,rice10:8,rice4:15,bag25to40:6};
  const int=(x,a,b)=>Number.isSafeInteger(x)&&x>=a&&x<=b;
  const rect=(c,col)=>({x:col.xMM,y:col.yMM,...cargo.size(c,col.kind,col.rotated)});
  const active=(g,t)=>g.start<=t&&t<g.end;
  function flowsFor(plan){
    const c=plan.cargo,a=c.autoLayout,errors=[],flows=[],remaining=new Map(),visitIDs=new Set(plan.visits.map(v=>v.id));
    for(const v of plan.visits){
      const seen=new Set();
      for(const order of v.orders){
        if(seen.has(order.id)||!cargo.kinds.includes(order.id))errors.push(v.name+': 주문 품목이 중복되거나 지원하지 않는 품목입니다.');seen.add(order.id);
        for(const operation of ['deliver','pickup'])remaining.set(JSON.stringify([v.id,order.id,operation]),order[operation]);
      }
    }
    if(!Array.isArray(a.transfers)||a.transfers.length>100)errors.push('매입→배송 연결은 100개까지 등록할 수 있습니다.');
    const transferIDs=new Set();
    for(const link of Array.isArray(a.transfers)?a.transfers:[]){
      if(!link.id||transferIDs.has(link.id)||!cargo.kinds.includes(link.kind)||!int(link.quantity,1,20000)||!visitIDs.has(link.fromID)||!visitIDs.has(link.toID)||link.fromID===link.toID){errors.push('매입→배송 연결의 품목·수량·서로 다른 거래처를 확인해 주세요.');continue;}
      transferIDs.add(link.id);
      for(const [id,op] of [[link.fromID,'pickup'],[link.toID,'deliver']]){
        const key=JSON.stringify([id,link.kind,op]),left=(remaining.get(key)||0)-link.quantity;remaining.set(key,left);
        if(left<0)errors.push('매입→배송 연결 수량이 해당 거래처의 주문을 넘습니다.');
      }
      flows.push({id:'transfer:'+link.id,kind:link.kind,quantity:link.quantity,loadAt:link.fromID,unloadAt:link.toID});
    }
    for(const v of plan.visits)for(const kind of cargo.kinds)for(const op of ['deliver','pickup']){
      const quantity=remaining.get(JSON.stringify([v.id,kind,op]))||0;
      if(quantity>0)flows.push({id:JSON.stringify([v.id,kind,op]),kind,quantity,loadAt:op==='deliver'?'depot':v.id,unloadAt:op==='deliver'?v.id:'depot'});
    }
    if(flows.reduce((n,f)=>n+f.quantity,0)>20000)errors.push('자동 배치 수량은 한 계획 합계 20000개까지 지원합니다.');
    return {flows,errors:[...new Set(errors)]};
  }
  function profileErrors(c,flows){
    const a=c.autoLayout,errors=[];
    for(const key of ['truckWidthMM','truckLengthMM','truckHeightMM','palletSideMM','palletHeightMM'])if(!int(c[key],1,20000))errors.push('화물칸·파렛트 실측 치수를 입력해 주세요.');
    if(!['compare','one','two'].includes(a.palletMode)||!['left','right'].includes(a.palletSide)||!['rear','left','right'].includes(a.accessSide))errors.push('파렛트 수·붙일 벽·작업문을 선택해 주세요.');
    const wallLength=a.accessSide==='rear'?c.truckWidthMM:c.truckLengthMM;
    if(!int(a.doorStartMM,0,20000)||!int(a.doorWidthMM,1,20000)||a.doorStartMM+a.doorWidthMM>wallLength)errors.push('작업문 개구부의 시작 위치와 실제 폭을 입력해 주세요.');
    if(c.palletSideMM>c.truckWidthMM||c.palletSideMM>c.truckLengthMM||c.palletHeightMM>=c.truckHeightMM)errors.push('파렛트가 화물칸에 들어가는지 실측 치수를 확인해 주세요.');
    for(const kind of new Set(flows.map(f=>f.kind))){
      const h=cargo.unitHeight(c,kind),s=cargo.size(c,kind,false);
      if(!int(h,1,1000)||!Number.isFinite(s.w)||!Number.isFinite(s.d)||s.w<=0||s.d<=0)errors.push(cargo.labels[kind]+': 실제 포장 치수를 입력해 주세요.');
      if(kind==='eggTray'&&!(4*c.eggSideMM<c.palletSideMM&&c.palletSideMM<5*c.eggSideMM))errors.push('계란판 한 변은 파렛트 한 변의 1/5보다 크고 1/4보다 작아야 합니다.');
      if(kind==='grainBox20'&&!int(a.boxMaxLayers,1,200))errors.push('박스 자동 배치에 사용할 최대 층수를 입력해 주세요.');
      if(kind==='rice4'&&!int(a.rice4MaxLayers,1,200))errors.push('4kg 낱포대 자동 배치에 사용할 최대 층수를 입력해 주세요.');
    }
    return [...new Set(errors)];
  }
  function subtract(free,obstacle){
    const out=[];
    for(const r of free){
      if(!cargo.overlap(r,obstacle)){out.push(r);continue;}
      const x0=Math.max(r.x,obstacle.x),x1=Math.min(r.x+r.w,obstacle.x+obstacle.w),y0=Math.max(r.y,obstacle.y),y1=Math.min(r.y+r.d,obstacle.y+obstacle.d);
      const pieces=[{x:r.x,y:r.y,w:x0-r.x,d:r.d},{x:x1,y:r.y,w:r.x+r.w-x1,d:r.d},{x:x0,y:r.y,w:x1-x0,d:y0-r.y},{x:x0,y:y1,w:x1-x0,d:r.y+r.d-y1}];
      out.push(...pieces.filter(p=>p.w>EPS&&p.d>EPS));
    }
    return out;
  }
  function depth(a,r){return a.accessSide==='rear'?r.y:a.accessSide==='right'?r.x:-r.x-r.w;}
  function layoutTemplates(c,flows){
    const a=c.autoLayout,types=[...new Set(flows.filter(f=>isBag(f.kind)).map(f=>f.kind))],out=[];
    const counts=a.palletMode==='one'?[1]:a.palletMode==='two'?[2]:[1,2];
    for(const count of counts){
      if(count*c.palletSideMM>c.truckLengthMM)continue;
      const choices=types.length?types.concat(''):[''];
      const combinations=count===1?choices.map(t=>[t]):choices.flatMap(x=>choices.map(y=>[x,y]));
      for(const assignment of combinations){
        if(types.some(t=>!assignment.includes(t)))continue;
        // Empty extra pallets are useful for boxes/support, so they are retained.
        for(let shape=0;shape<4;shape++)out.push({count,assignment,shape});
      }
    }
    return out;
  }
  function geometry(profile,template,flows,boxMode){
    const c=copy(profile),a=c.autoLayout,p=c.palletSideMM;
    c.autoLayout=null;c.enabled=true;c.pallets=[];c.columns=[];c.lots=[];
    c.accessGeometry={side:a.accessSide,startMM:a.doorStartMM,widthMM:a.doorWidthMM};
    const palletX=a.palletSide==='left'?0:c.truckWidthMM-p;
    function add(kind,x,y,palletID,rotated){
      if(c.columns.length>=160)return null;
      const s=cargo.size(c,kind,rotated),near=a.accessSide==='rear'?x:y,far=near+(a.accessSide==='rear'?s.w:s.d);
      if(near<a.doorStartMM-EPS||far>a.doorStartMM+a.doorWidthMM+EPS)return null;
      const col={id:'auto-column-'+c.columns.length,name:cargo.labels[kind]+' 자리 '+(c.columns.length+1),kind,xMM:x,yMM:y,palletID,rotated:!!rotated,maxHeightMM:c.truckHeightMM-(palletID?c.palletHeightMM:0),accessConfirmed:false,accessSource:'geometry',blockedByIDs:[],supports:['left','right','front','rear'].map(direction=>({direction,targetID:'',mode:'contact'})),maxUnitsByKind:{}};
      if(kind==='rice4')col.maxUnitsByKind.rice4=a.rice4MaxLayers;
      if(flows.some(f=>f.kind==='grainBox20'))col.maxUnitsByKind.grainBox20=a.boxMaxLayers;
      c.columns.push(col);return col;
    }
    for(let i=0;i<template.count;i++){
      const pallet={id:'auto-pallet-'+i,name:'파렛트 '+(i+1),xMM:palletX,yMM:i*p};c.pallets.push(pallet);
      const kind=template.assignment[i];if(!kind)continue;
      const rotated=!!(template.shape%2),s=cargo.size(c,kind,rotated),nx=Math.floor((p+EPS)/s.w),ny=Math.floor((p+EPS)/s.d),count=Math.min(caps[kind],nx*ny);
      if(!count)return {error:cargo.labels[kind]+': 이 격자 패턴에 놓을 수 없습니다.'};
      for(let j=0;j<count;j++){
        const index=template.shape<2?j:nx*ny-count+j;
        add(kind,palletX+(index%nx)*s.w,i*p+Math.floor(index/nx)*s.d,pallet.id,rotated);
      }
    }
    const palletRects=c.pallets.map(q=>({x:q.xMM,y:q.yMM,w:p,d:p}));
    let floor=[{x:0,y:0,w:c.truckWidthMM,d:c.truckLengthMM}];for(const r of palletRects)floor=subtract(floor,r);
    let palletFree=palletRects.map((r,i)=>({...r,palletID:c.pallets[i].id}));
    for(const col of c.columns)palletFree=palletFree.flatMap(r=>subtract([r],rect(c,col)).map(v=>({...v,palletID:r.palletID})));
    function clipToDoor(rectangles){return rectangles.flatMap(r=>{
      const lo=Math.max(a.accessSide==='rear'?r.x:r.y,a.doorStartMM),hi=Math.min(a.accessSide==='rear'?r.x+r.w:r.y+r.d,a.doorStartMM+a.doorWidthMM);
      return hi>lo+EPS?[a.accessSide==='rear'?{...r,x:lo,w:hi-lo}:{...r,y:lo,d:hi-lo}]:[];
    });}
    floor=clipToDoor(floor);palletFree=clipToDoor(palletFree);
    const boxTotal=flows.filter(f=>f.kind==='grainBox20').reduce((n,f)=>n+f.quantity,0);
    const boxCount=boxMode==='top'?0:Math.min(160-c.columns.length,Math.ceil(boxTotal/Math.max(1,a.boxMaxLayers)));
    let available=floor.map(r=>({...r,palletID:''})).concat(palletFree);
    for(let i=0;i<boxCount;i++){
      available.sort((r,s)=>depth(a,r)-depth(a,s)||r.x-s.x);
      let placed=null;
      for(const r of available){
        for(const rotate of [false,true]){const s=cargo.size(c,'grainBox20',rotate);if(s.w<=r.w+EPS&&s.d<=r.d+EPS){placed={r,s,rotate};break;}}
        if(placed)break;
      }
      if(!placed)break;
      const {r,s,rotate}=placed,x=(template.shape%2)?r.x+r.w-s.w:r.x,y=r.y;
      const col=add('grainBox20',x,y,r.palletID,rotate);if(!col)break;
      const occupied=rect(c,col);available=available.flatMap(v=>subtract([v],occupied).map(w=>({...w,palletID:v.palletID})));
      if(!r.palletID)floor=subtract(floor,occupied);
    }
    if(flows.some(f=>f.kind==='eggTray')){
      // Fill only pallet-free floor rectangles; one tray footprint per column.
      for(const r of floor){
        const e=c.eggSideMM,nx=Math.floor((r.w+EPS)/e),ny=Math.floor((r.d+EPS)/e);
        for(let j=0;j<nx*ny&&c.columns.length<160;j++){
          const x=a.palletSide==='left'?r.x+r.w-e-(j%nx)*e:r.x+(j%nx)*e;
          add('eggTray',x,r.y+Math.floor(j/nx)*e,'',false);
        }
      }
    }
    // Straight horizontal movement at the unit's current stack height. A lower
    // stack may be cleared, but lifting a unit above its own height is not assumed.
    for(const col of c.columns){
      const access=cargo.deriveAccess(c,col,c.columns,c.accessGeometry);
      col.blockedByIDs=access.blockedByIDs;col.accessMinimumHeightMM=access.accessMinimumHeightMM;
    }
    return {config:c};
  }
  function candidatesForSupport(c,col,direction,openSide){
    // Generated positions lie in the door projection. The open working door
    // cannot supply a supporting wall while a delivery/pickup is performed.
    const r=rect(c,col),targets=direction===openSide?[]:[{id:'wall:'+direction,rect:{wall:direction,width:c.truckWidthMM,length:c.truckLengthMM},permanent:c.truckHeightMM}];
    for(const p of c.pallets)targets.push({id:'pallet:'+p.id,rect:{x:p.xMM,y:p.yMM,w:c.palletSideMM,d:c.palletSideMM},permanent:c.palletHeightMM});
    for(const other of c.columns)if(other.id!==col.id)targets.push({id:'column:'+other.id,rect:rect(c,other),column:other});
    return targets.flatMap(t=>{
      const mode=cargo.adjacent(r,t.rect,direction,'contact',c.eggSideMM)?'contact':cargo.adjacent(r,t.rect,direction,'narrow',c.eggSideMM)?'narrow':null;
      return mode?[{...t,mode}]:[];
    });
  }
  function placeFlows(config,flows,order,profile,eggMode,boxMode){
    const c=config,a=profile.autoLayout,n=order.length,rank=new Map(order.map((id,i)=>[id,i+1])),stock=new Map(c.columns.map(col=>[col.id,[]]));
    const timed=flows.map(f=>({...f,start:f.loadAt==='depot'?0:rank.get(f.loadAt),end:f.unloadAt==='depot'?n+1:rank.get(f.unloadAt)}));
    if(timed.some(f=>f.start>=f.end))return {error:'매입→배송의 방문 순서가 뒤바뀝니다.'};
    const boxesFit=col=>{const s=cargo.size(c,'grainBox20',false),r=rect(c,col);return(s.w<=r.w+EPS&&s.d<=r.d+EPS)||(s.d<=r.w+EPS&&s.w<=r.d+EPS);};
    const height=(col,t)=>stock.get(col.id).filter(g=>active(g,t)).reduce((h,g)=>h+g.quantity*cargo.unitHeight(c,g.kind),0);
    const counts=(col,kind,t)=>stock.get(col.id).filter(g=>g.kind===kind&&active(g,t)).reduce((q,g)=>q+g.quantity,0);
    const limits={rice20:10,rice10:13,rice4:a.rice4MaxLayers,bag25to40:5,grainBox20:a.boxMaxLayers};
    for(const col of c.columns)if(col.kind==='eggTray'){
      const surrounded=['left','right','front','rear'].every(d=>candidatesForSupport(c,col,d,a.accessSide).length);
      col.maxUnitsByKind.eggTray=eggMode==='low'||!surrounded?5:Math.floor(col.maxHeightMM/c.eggTrayHeightMM);
    }
    const kindPriority=k=>isBag(k)?0:k==='grainBox20'?1:2;
    timed.sort((f,g)=>f.start-g.start||kindPriority(f.kind)-kindPriority(g.kind)||g.end-f.end);
    let nextID=0;
    for(const flow of timed){
      let left=flow.quantity;
      const choices=c.columns.filter(col=>col.kind===flow.kind||(flow.kind==='grainBox20'&&isBag(col.kind)&&boxesFit(col)));
      while(left>0){
        choices.sort((x,y)=>{
          if(flow.kind==='grainBox20'&&x.kind!==y.kind)return ((x.kind==='grainBox20'?1:0)-(y.kind==='grainBox20'?1:0))*(boxMode==='floor'?-1:1);
          if(flow.kind==='eggTray'&&eggMode==='balanced')return counts(x,flow.kind,flow.start)-counts(y,flow.kind,flow.start)||depth(a,rect(c,x))-depth(a,rect(c,y));
          return depth(a,rect(c,x))-depth(a,rect(c,y))||x.xMM-y.xMM;
        });
        let chosen=null,amount=0;
        for(const col of choices){
          const live=stock.get(col.id).filter(g=>active(g,flow.start));
          if(live.some(g=>g.end<flow.end))continue; // Never cover an earlier delivery.
          if(isBag(flow.kind)&&live.some(g=>g.kind==='grainBox20'))continue;
          const ceiling=limits[flow.kind]||col.maxUnitsByKind.eggTray;
          let room=Math.min(ceiling-counts(col,flow.kind,flow.start),Math.floor((col.maxHeightMM-height(col,flow.start)+EPS)/cargo.unitHeight(c,flow.kind)));
          if(room<=0)continue;
          let blocked=false;
          for(const id of col.blockedByIDs)for(const g of stock.get(id)){
            if((flow.start>0&&active(g,flow.start))||(g.start<flow.end&&g.end>flow.end)){blocked=true;break;}
          }
          // This new group must not hide a shipment already allocated elsewhere.
          for(const other of c.columns)if(other.blockedByIDs.includes(col.id))for(const g of stock.get(other.id)){
            if((g.end>flow.start&&g.end<flow.end)||(g.start>flow.start&&g.start<flow.end)){blocked=true;break;}
          }
          if(blocked)continue;
          chosen=col;amount=Math.min(left,room,flow.kind==='eggTray'&&eggMode==='balanced'?1:20000);break;
        }
        if(!chosen)return {error:cargo.labels[flow.kind]+': 이 방문 순서·배치에서 높이·덮임·통로 조건을 만족하는 자리가 부족합니다.'};
        const groups=stock.get(chosen.id);let group=groups.find(g=>g.flowID===flow.id);
        if(group){group.quantity+=amount;c.lots.find(l=>l.id===group.lotID).quantity+=amount;}
        else{
          const id='auto-lot-'+nextID++;
          group={...flow,quantity:amount,flowID:flow.id,lotID:id};groups.push(group);
          c.lots.push({id,columnID:chosen.id,kind:flow.kind,quantity:amount,loadAt:flow.loadAt,unloadAt:flow.unloadAt,stackOrder:nextID});
        }
        left-=amount;if(c.lots.length>600)return {error:'자동 배치 묶음 600개 탐색 한도에 도달했습니다.'};
      }
    }
    function supportingHeight(col,t){
      let result=col.palletID?c.palletHeightMM:0;
      for(const g of stock.get(col.id).filter(g=>active(g,t))){
        if(g.kind==='grainBox20'&&isBag(col.kind)){
          const b=cargo.size(c,g.kind,false),r=rect(c,col);
          if(!((Math.abs(b.w-r.w)<EPS&&Math.abs(b.d-r.d)<EPS)||(Math.abs(b.d-r.w)<EPS&&Math.abs(b.w-r.d)<EPS)))break;
        }
        result+=g.quantity*cargo.unitHeight(c,g.kind);
      }
      return result;
    }
    for(const col of c.columns)if(col.kind==='eggTray'){
      const times=Array.from({length:n+1},(_,i)=>i).filter(t=>counts(col,'eggTray',t)>0);
      col.supports=col.supports.map(s=>{
        const candidates=candidatesForSupport(c,col,s.direction,a.accessSide).map(t=>({...t,score:t.permanent!==undefined?t.permanent:Math.min(...(times.length?times:[0]).map(time=>supportingHeight(t.column,time)))})).sort((x,y)=>y.score-x.score||(x.mode==='contact'?-1:1));
        return candidates.length?{direction:s.direction,targetID:candidates[0].id,mode:candidates[0].mode}:s;
      });
    }
    // Unused floor slots are kept for geometric access checks but do not support
    // eggs as if they contained cargo; the replay engine checks actual contents.
    return {config:c};
  }
  function forceOrder(plan,order){
    const p=copy(plan),positions=new Map(order.map((id,i)=>[id,i+1]));
    for(const v of p.visits){if(v.fixedPosition&&v.fixedPosition!==positions.get(v.id))return null;v.fixedPosition=positions.get(v.id);}
    return p;
  }
  function solve(plan,options,solveBase){
    const start=Date.now(),opt=options||{},deadline=start+(opt.maxMilliseconds||15000),input=copy(plan),a=input.cargo.autoLayout;
    const plain=copy(input);plain.cargo.enabled=false;
    let base=solveBase(plain,{maxMilliseconds:Math.min(2000,Math.max(1,deadline-Date.now())),candidateLimit:8,width:opt.width||250});
    if(base.status==='invalid')return {...base,searchComplete:false};
    const flows=flowsFor(input),errors=flows.errors.concat(profileErrors(input.cargo,flows.flows));
    if(base.status==='invalid'||errors.length)return {...base,status:'invalid',rows:[],finishMinute:null,originDepartureMinute:null,cargo:null,loadingValidated:false,messages:errors.length?errors:base.messages,searchComplete:false};
    // A linked pickup must precede its delivery in every generated seed.
    const linked=copy(plain);
    for(const t of a.transfers){const v=linked.visits.find(v=>v.id===t.toID);if(!v.afterIDs.includes(t.fromID))v.afterIDs.push(t.fromID);}
    const seeds=[],keys=new Set();
    function add(order){if(order.length!==input.visits.length)return;const k=JSON.stringify(order);if(!keys.has(k)){keys.add(k);seeds.push(order);}}
    for(const s of base.routeAlternatives||[])add(s.visitIDs);
    if(a.transfers.length&&Date.now()<deadline){const r=solveBase(linked,{maxMilliseconds:1000,candidateLimit:4,width:200});for(const s of r.routeAlternatives||[])add(s.visitIDs);}
    const pickupLast=copy(linked),purePickups=pickupLast.visits.filter(v=>v.orders.some(o=>o.pickup>0)&&!v.orders.some(o=>o.deliver>0)&&!a.transfers.some(t=>t.fromID===v.id));
    for(const v of purePickups)for(const earlier of pickupLast.visits)if(earlier.id!==v.id&&!purePickups.includes(earlier)&&!v.afterIDs.includes(earlier.id))v.afterIDs.push(earlier.id);
    if(purePickups.length&&Date.now()<deadline){const r=solveBase(pickupLast,{maxMilliseconds:1000,candidateLimit:3,width:200});for(const s of r.routeAlternatives||[])add(s.visitIDs);}
    if(!seeds.length)return {...base,status:'not_found',messages:base.messages.concat('자동 배치의 기준이 될 방문 순서를 찾지 못했습니다. 시간·순서·이동 구간을 확인해 주세요.'),searchComplete:false,elapsedMilliseconds:Date.now()-start};
    // Promote substantially different seeds (including pickup-last) before many
    // near-identical travel ties; then add a few local swaps without relaxing constraints.
    const initial=seeds.slice();if(seeds.length>2){const last=seeds.pop();seeds.splice(1,0,last);}
    for(const order of initial.slice(0,2))for(let i=0;i<order.length-1&&seeds.length<16;i++){const swap=order.slice();[swap[i],swap[i+1]]=[swap[i+1],swap[i]];add(swap);}
    const templates=layoutTemplates(input.cargo,flows.flows),reasons=new Set(),seenConfigs=new Set();
    if(!templates.length)reasons.add('현재 자동 배치는 파렛트별 한 규격, 앞뒤 배치만 비교합니다. 선택한 파렛트 수·화물칸 길이·포대 규격 수에 맞는 패턴이 없습니다.');
    let best=null,tested=0,feasible=0,attempts=0,timedOut=false;
    const maxAttempts=opt.maxLayouts||192;
    const hasBoxes=flows.flows.some(f=>f.kind==='grainBox20'),hasEggs=flows.flows.some(f=>f.kind==='eggTray');
    const passes=[{box:hasBoxes?'floor':'top',egg:'low'}];
    if(hasBoxes)passes.push({box:'top',egg:'low'});
    if(hasEggs)passes.push({box:hasBoxes?'floor':'top',egg:'balanced'});
    outer:for(const order of seeds)for(let shape=0;shape<4;shape++)for(const template of templates.filter(t=>t.shape===shape)){
      for(const pass of passes){
        if(pass.egg==='balanced'&&!hasEggs)continue;
        if(attempts++>=maxAttempts||Date.now()>deadline){timedOut=Date.now()>deadline;break outer;}
        const forced=forceOrder(input,order);if(!forced)continue;
        const geometric=geometry(input.cargo,template,flows.flows,pass.box);if(geometric.error){if(reasons.size<5)reasons.add(geometric.error);continue;}
        const placed=placeFlows(geometric.config,flows.flows,order,input.cargo,pass.egg,pass.box);
        if(placed.error){if(reasons.size<5)reasons.add(placed.error);continue;}
        const fingerprint=JSON.stringify([order,placed.config]);if(seenConfigs.has(fingerprint))continue;seenConfigs.add(fingerprint);
        forced.cargo=placed.config;tested++;
        const r=solveBase(forced,{maxMilliseconds:Math.max(1,Math.min(1500,deadline-Date.now())),cargoOptions:opt.cargoOptions});
        if(r.status!=='candidate'){if(reasons.size<5)reasons.add(r.messages[0]||'상하차 순서 검사 실패');continue;}
        feasible++;
        if(!best||r.finishMinute<best.result.finishMinute||(r.finishMinute===best.result.finishMinute&&(r.totalTravelMinutes<best.result.totalTravelMinutes||(r.totalTravelMinutes===best.result.totalTravelMinutes&&placed.config.pallets.length<best.config.pallets.length))))best={result:r,config:placed.config};
      }
    }
    if(best){
      // Improve the route once more with the selected fixed geometry/lots.
      const refine=copy(input);refine.cargo=best.config;
      if(deadline-Date.now()>250){const r=solveBase(refine,{maxMilliseconds:Math.min(1500,deadline-Date.now()),width:200});if(r.status==='candidate'&&(r.finishMinute<best.result.finishMinute||(r.finishMinute===best.result.finishMinute&&r.totalTravelMinutes<best.result.totalTravelMinutes)))best.result=r;}
    }
    const summary={attemptedLayouts:Math.min(attempts,maxAttempts),validatedLayouts:tested,feasibleLayouts:feasible,routeSeeds:seeds.length,palletCount:best?best.config.pallets.length:0,timeLimited:timedOut,patternSearchComplete:false,accessSide:a.accessSide};
    const messages=[best?'주문에서 적재 배치를 자동 생성하고 방문 순서·상하차 중간 상태를 검사했습니다.':'탐색한 자동 배치 패턴 안에서 완성된 경로를 찾지 못했습니다. 모든 적재 방법이 불가능하다는 뜻은 아닙니다.',
      '파렛트·격자 배치와 제한된 방문 순서 후보를 비교했습니다. 배치와 경로의 전역 최적해는 보장하지 않습니다.',
      '선택한 작업문으로 화물을 같은 높이에서 수평 이동하는 통로 모델입니다. 열린 작업문은 계란 지지물로 세지 않습니다. 재배치를 켜면 등록한 자리 사이 이동을 반영합니다. 더 높이 들어올려 넘기기·차량 밖 임시 하차·총중량·실차 안정성은 포함하지 않습니다.'];
    if(best)messages.push(...best.result.messages.filter(m=>m.includes('도로')));
    if(!best)messages.push(...reasons);
    const result={...(best?best.result:base),status:best?'candidate':'not_found',messages,searchComplete:false,generatedCargo:best?best.config:null,automaticLoading:summary,elapsedMilliseconds:Date.now()-start,globalRoadOptimalityProven:false};
    if(!best)Object.assign(result,{rows:[],finishMinute:null,originDepartureMinute:null,lastWorkFinishMinute:null,rest:null,returnMinutes:0,totalTravelMinutes:0,cargo:null,loadingValidated:false,returnLegID:null,roadEvidenceValidated:false,heightProfileValidated:false,class1TollValidated:false,totalClass1TollWon:null,selectedRoadEvidence:[]});
    delete result.routeAlternatives;return result;
  }
  return {solve,flowsFor,geometry,placeFlows,layoutTemplates,profileErrors};
})();
if(typeof module!=='undefined'&&module.exports)module.exports=DeliveryAutoCargo;
