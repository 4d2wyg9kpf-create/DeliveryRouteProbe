/* Registered load patterns, not a free-form packing or vehicle stability simulator.
   Coordinates/heights are mm. Initial lot order is bottom -> top in each column.
   Optional rehandling moves goods between registered positions and checks each intermediate state. */
var DeliveryCargo = (function () {
  'use strict';
  const kinds = ['rice20','rice10','rice4','bag25to40','grainBox20','eggTray'];
  const labels = {rice20:'쌀 20kg',rice10:'쌀 10kg',rice4:'쌀 4kg 낱포대',bag25to40:'25~40kg 포대',grainBox20:'곡류 박스',eggTray:'계란 판'};
  const layerLimits = {rice20:10,rice10:13,bag25to40:5};
  const sides = ['left','right','front','rear'];
  const sideNames = {left:'왼쪽',right:'오른쪽',front:'앞쪽',rear:'뒤쪽'};
  const EPS = 0.000001;
  const validInt = (v,a,b) => Number.isSafeInteger(v) && v>=a && v<=b;
  const coordinate = v => typeof v==='number' && Number.isFinite(v) && v>=0 && v<=20000;
  const overlap = (a,b) => a.x < b.x+b.w-EPS && b.x < a.x+a.w-EPS && a.y < b.y+b.d-EPS && b.y < a.y+a.d-EPS;
  const inside = (a,b) => a.x>=b.x-EPS && a.y>=b.y-EPS && a.x+a.w<=b.x+b.w+EPS && a.y+a.d<=b.y+b.d+EPS;
  const rice = k => /^rice/.test(k)||k==='bag25to40';
  const clone = state => state.map(col=>col.map(g=>({lot:g.lot,quantity:g.quantity})));
  const stateKey = state => state.map(col=>col.map(g=>g.lot+':'+g.quantity).join(',')).join('|');
  function size(c, kind, rotated) {
    let w=0,d=0;
    if(kind==='rice20'){w=c.palletSideMM/3;d=c.palletSideMM/2;}
    if(kind==='rice10'){w=c.rice10WidthMM;d=c.palletSideMM-2*w;}
    if(kind==='rice4'){w=c.palletSideMM/5;d=c.palletSideMM/3;}
    if(kind==='bag25to40'){w=c.bulkBagWidthMM;d=c.bulkBagDepthMM;}
    if(kind==='eggTray')w=d=c.eggSideMM;
    if(kind==='grainBox20'){w=c.boxWidthMM;d=c.boxDepthMM;}
    return rotated?{w:d,d:w}:{w,d};
  }
  function unitHeight(c,k) {
    return ({rice20:c.rice20HeightMM,rice10:c.rice10HeightMM,rice4:c.rice4HeightMM,bag25to40:c.bulkBagHeightMM,grainBox20:c.boxHeightMM,eggTray:c.eggTrayHeightMM})[k];
  }
  function deriveAccess(c,col,columns,profile){
    const r={x:col.xMM,y:col.yMM,...size(c,col.kind,col.rotated)},side=profile.side;
    const blocks=s=>side==='rear'?(s.y>=r.y+r.d-EPS&&s.x<r.x+r.w-EPS&&r.x<s.x+s.w-EPS):side==='right'?(s.x>=r.x+r.w-EPS&&s.y<r.y+r.d-EPS&&r.y<s.y+s.d-EPS):(s.x+s.w<=r.x+EPS&&s.y<r.y+r.d-EPS&&r.y<s.y+s.d-EPS);
    const near=side==='rear'?r.x:r.y,far=near+(side==='rear'?r.w:r.d);
    return {
      fitsDoor:near>=profile.startMM-EPS&&far<=profile.startMM+profile.widthMM+EPS,
      blockedByIDs:columns.filter(other=>other.id!==col.id&&blocks({x:other.xMM,y:other.yMM,...size(c,other.kind,other.rotated)})).map(other=>other.id),
      accessMinimumHeightMM:c.pallets.some(p=>blocks({x:p.xMM,y:p.yMM,w:c.palletSideMM,d:c.palletSideMM}))?c.palletHeightMM:0
    };
  }
  function prepare(plan) {
    const c=plan.cargo;
    if(!c || c.enabled===false)return {enabled:false,errors:[]};
    const errors=[];
    const bad = message => errors.push('적재: '+message);
    if(c.enabled!==true)return {enabled:true,errors:['적재 사용 여부를 확인해 주세요.']};
    for(const f of ['truckWidthMM','truckLengthMM','truckHeightMM','palletSideMM','palletHeightMM'])
      if(!validInt(c[f],1,20000))bad('화물칸·파렛트 실측 치수를 1~20000mm로 입력해 주세요.');
    if(!Array.isArray(c.pallets)||c.pallets.length<1||c.pallets.length>2)bad('파렛트는 1장 또는 2장을 등록해 주세요.');
    if(!Array.isArray(c.columns)||c.columns.length>160||!Array.isArray(c.lots)||c.lots.length>600)bad('적재 위치는 160개, 배치 묶음은 600개까지 지원합니다.');
    if(c.rehandling&&(typeof c.rehandling.enabled!=='boolean'||!validInt(c.rehandling.maxMovedUnits,1,40)||!validInt(c.rehandling.secondsPerUnit,1,3600)||!validInt(c.rehandling.setupMinutes,0,60)))bad('재배치 한도(1~40개), 개당 시간(1~3600초), 준비시간(0~60분)을 확인해 주세요.');
    if(errors.length)return {enabled:true,errors:[...new Set(errors)]};
    const truck={x:0,y:0,w:c.truckWidthMM,d:c.truckLengthMM};
    const pallets=new Map(),columnIDs=new Map(),lotIDs=new Set();
    for(const p of c.pallets){
      if(typeof p.id!=='string'||!p.id||pallets.has(p.id))bad('파렛트 식별자가 없거나 중복됩니다.');
      const rect={x:p.xMM,y:p.yMM,w:c.palletSideMM,d:c.palletSideMM};
      if(!validInt(p.xMM,0,20000)||!validInt(p.yMM,0,20000)||!inside(rect,truck))bad((p.name||'파렛트')+'가 화물칸 밖에 있습니다.');
      for(const prior of pallets.values())if(overlap(rect,prior.rect))bad('파렛트끼리 겹칩니다.');
      pallets.set(p.id,{...p,rect});
    }
    const usedKinds=new Set([...c.columns.map(x=>x.kind),...c.lots.map(x=>x.kind)]);
    for(const kind of usedKinds){
      if(!kinds.includes(kind)){bad('지원하지 않는 품목이 있습니다.');continue;}
      if(!validInt(unitHeight(c,kind),1,1000))bad(labels[kind]+'의 한 개 높이를 입력해 주세요.');
      if(kind==='rice10' && (!validInt(c.rice10WidthMM,1,2000)||c.palletSideMM-2*c.rice10WidthMM<=0))bad('10kg 포대 폭을 확인해 주세요. 길이는 파렛트 한 변−폭×2로 계산합니다.');
      if(kind==='eggTray' && (!validInt(c.eggSideMM,1,2000)||!(4*c.eggSideMM<c.palletSideMM && c.palletSideMM<5*c.eggSideMM)))bad('계란판 한 변은 파렛트 한 변의 1/5보다 크고 1/4보다 작아야 합니다.');
      if(kind==='grainBox20' && (!validInt(c.boxWidthMM,1,5000)||!validInt(c.boxDepthMM,1,5000)))bad('곡류 박스의 실제 외부 폭·길이를 입력해 주세요.');
      if(kind==='bag25to40'){
        const s=size(c,kind,false),p=c.palletSideMM;
        if(!validInt(s.w,1,5000)||!validInt(s.d,1,5000)||!((s.w<=p/3+EPS&&s.d<=p/2+EPS)||(s.d<=p/3+EPS&&s.w<=p/2+EPS)))bad('25~40kg 포대의 실측 폭·길이와 파렛트 3×2 배치를 확인해 주세요.');
      }
    }
    const columns=c.columns.map((col,i)=>{
      if(typeof col.id!=='string'||!col.id||columnIDs.has(col.id))bad('적재 위치 식별자가 없거나 중복됩니다.');
      columnIDs.set(col.id,i);
      const rect={x:col.xMM,y:col.yMM,...size(c,col.kind,col.rotated)};
      const p=pallets.get(col.palletID),base=p?c.palletHeightMM:0;
      if(!String(col.name||'').trim())bad('적재 위치 이름을 입력해 주세요.');
      if(!coordinate(col.xMM)||!coordinate(col.yMM)||!inside(rect,truck))bad(col.name+': 화물칸 밖의 위치입니다.');
      if(col.palletID && !p)bad(col.name+': 받침 파렛트가 없습니다.');
      if(rice(col.kind) && !p && col.temporaryFloor!==true)bad(col.name+': 쌀포대는 파렛트 위에 놓아야 합니다.');
      if(col.kind==='eggTray' && p)bad(col.name+': 이번 배치 모델에서 계란은 바닥 빈 공간에 놓습니다.');
      if(p && !inside(rect,p.rect))bad(col.name+': 받침 파렛트 밖으로 돌출됩니다.');
      if(!p)for(const pallet of pallets.values())if(overlap(rect,pallet.rect))bad(col.name+': 빈 파렛트도 바닥 면적을 차지합니다.');
      if(!validInt(col.maxHeightMM,1,20000)||col.maxHeightMM+base>c.truckHeightMM)bad(col.name+': 받침 위 허용 적재 높이와 화물칸 높이를 확인해 주세요.');
      if(col.accessConfirmed!==true && col.accessSource!=='geometry')bad(col.name+': 사용할 하역 통로와 통로를 막는 위치를 확인해 주세요.');
      if(col.maxUnitsByKind && (typeof col.maxUnitsByKind!=='object'||Object.entries(col.maxUnitsByKind).some(([k,n])=>!kinds.includes(k)||!validInt(n,1,20000))))bad(col.name+': 품목별 적층 한도를 확인해 주세요.');
      if(!Array.isArray(col.blockedByIDs)||!Array.isArray(col.supports))bad(col.name+': 통로·지지 설정 형식이 잘못됐습니다.');
      return {...col,rect,base,index:i};
    });
    if(columns.some(col=>col.accessSource==='geometry')){
      const g=c.accessGeometry,wallLength=g?.side==='rear'?c.truckWidthMM:c.truckLengthMM;
      if(!g||!sides.includes(g.side)||g.side==='front'||!validInt(g.startMM,0,20000)||!validInt(g.widthMM,1,20000)||g.startMM+g.widthMM>wallLength)bad('자동 통로의 작업문 개구부를 확인해 주세요.');
      else for(const col of columns)if(col.accessSource==='geometry'){
        const access=deriveAccess(c,col,columns,g);
        if(!access.fitsDoor)bad(col.name+': 작업문 개구부 밖의 직선 통로입니다.');
        col.blockedByIDs=access.blockedByIDs;col.accessMinimumHeightMM=access.accessMinimumHeightMM;
        if(col.kind==='eggTray'&&(col.supports||[]).some(s=>s.targetID==='wall:'+g.side))bad(col.name+': 열린 작업문은 계란 지지벽으로 사용할 수 없습니다.');
      }
    }
    for(let i=0;i<columns.length;i++)for(let j=i+1;j<columns.length;j++)
      if(!columns[i].alternativePosition&&!columns[j].alternativePosition&&overlap(columns[i].rect,columns[j].rect))bad(columns[i].name+'와 '+columns[j].name+': 바닥 면적이 겹칩니다. 같은 더미의 곡류 박스는 별도 위치 대신 같은 위치에 배치합니다.');
    for(const p of pallets.values()){
      const on=columns.filter(x=>x.palletID===p.id&&rice(x.kind)),types=new Set(on.map(x=>x.kind));
      if(types.size>1)bad((p.name||'파렛트')+': 이번 버전의 한 파렛트에는 한 규격의 쌀 위치만 등록합니다.');
      const cap={rice20:5,rice10:8,rice4:15,bag25to40:6};
      if(on.length && on.filter(col=>!col.alternativePosition).length>cap[on[0].kind])bad((p.name||'파렛트')+': 한 층 자리 수가 20kg 5포·10kg 8포·4kg 15포·25~40kg 6포 기준을 넘습니다.');
    }
    for(const col of columns){
      for(const id of col.blockedByIDs||[])if(!columnIDs.has(id)||id===col.id)bad(col.name+': 통로를 막는 위치가 없거나 자기 자신입니다.');
      const directions=new Set();
      for(const support of col.supports||[]){
        if(!sides.includes(support.direction)||directions.has(support.direction))bad(col.name+': 지지 방향이 없거나 중복됩니다.');
        directions.add(support.direction);
        if(!support.targetID)continue;
        if(!['contact','narrow'].includes(support.mode))bad(col.name+': 지지 접촉 방식을 확인해 주세요.');
        const target=targetGeometry(c,pallets,columns,columnIDs,support.targetID);
        if(!target||support.targetID==='column:'+col.id)bad(col.name+': 지지물이 없거나 자기 자신입니다.');
        else if(!adjacent(col.rect,target,support.direction,support.mode,c.eggSideMM))bad(col.name+': '+sideNames[support.direction]+' 지지물의 방향·간격·면의 겹침을 확인해 주세요.');
      }
    }
    const visits=new Map(plan.visits.map(x=>[x.id,x]));
    const lots=c.lots.map((lot,i)=>{
      const col=columns[columnIDs.get(lot.columnID)];
      if(typeof lot.id!=='string'||!lot.id||lotIDs.has(lot.id))bad('배치 묶음 식별자가 없거나 중복됩니다.');
      lotIDs.add(lot.id);
      if(!col)bad('배치 묶음의 적재 위치가 없습니다.');
      else {
        if(lot.kind!==col.kind && !(lot.kind==='grainBox20'&&rice(col.kind)))bad(col.name+': 이 위치에서 지원하지 않는 품목입니다.');
        if(lot.kind==='grainBox20'){
          const s=size(c,lot.kind,false),r=col.rect;
          if(!((s.w<=r.w+EPS&&s.d<=r.d+EPS)||(s.d<=r.w+EPS&&s.w<=r.d+EPS)))bad(col.name+': 박스 바닥이 쌀 받침보다 큽니다.');
        }
      }
      if(!validInt(lot.quantity,1,20000)||!validInt(lot.stackOrder,1,100000))bad('배치 수량·쌓임 번호는 양의 정수여야 합니다.');
      if((lot.loadAt!=='depot'&&!visits.has(lot.loadAt))||(lot.unloadAt!=='depot'&&!visits.has(lot.unloadAt))||lot.loadAt===lot.unloadAt)bad('화물을 싣는 곳과 내리는 곳을 서로 다르게 지정해 주세요.');
      return {...lot,index:i,column:col?col.index:-1};
    });
    if(lots.reduce((a,l)=>a+(Number(l.quantity)||0),0)>20000)bad('한 계획의 배치 수량은 합계 20000개까지 지원합니다.');
    const orders=new Map();
    for(const l of lots)for(const [where,field] of [[l.loadAt,'pickup'],[l.unloadAt,'deliver']])if(where!=='depot'){
      const k=JSON.stringify([where,l.kind,field]);orders.set(k,(orders.get(k)||0)+l.quantity);
    }
    for(const v of plan.visits){
      const seen=new Set();
      for(const o of v.orders||[]){
        if(seen.has(o.id)||!kinds.includes(o.id))bad(v.name+': 주문 품목이 중복되거나 지원하지 않는 품목입니다.');seen.add(o.id);
      }
      for(const kind of kinds)for(const field of ['deliver','pickup']){
        const expected=(v.orders||[]).find(o=>o.id===kind)?.[field]||0;
        const actual=orders.get(JSON.stringify([v.id,kind,field]))||0;
        if(expected!==actual)bad(v.name+': '+labels[kind]+' '+(field==='deliver'?'배송':'매입')+' 주문 '+expected+'개와 배치 '+actual+'개가 다릅니다.');
      }
    }
    const positions=new Set();
    for(const l of lots){const k=JSON.stringify([l.columnID,l.loadAt,l.stackOrder]);if(positions.has(k))bad('같은 위치·상차 장소의 쌓임 번호가 중복됩니다.');positions.add(k);}
    const initial=columns.map(()=>[]);
    for(const l of lots.filter(l=>l.loadAt==='depot').sort((a,b)=>a.stackOrder-b.stackOrder))if(l.column>=0)initial[l.column].push({lot:l.index,quantity:l.quantity});
    const data={enabled:true,errors:[...new Set(errors)],config:c,pallets,columns,columnIDs,lots,initial,hasEggs:usedKinds.has('eggTray'),hasGeometryAccess:columns.some(col=>col.accessSource==='geometry'),cache:new Map()};
    if(!data.errors.length){const reason=checkState(data,initial);if(reason)data.errors.push('회사 출발 배치: '+reason);}
    return data;
  }
  function targetGeometry(c,pallets,columns,ids,id){
    if(id.startsWith('wall:')){
      const d=id.slice(5);return sides.includes(d)?{wall:d,width:c.truckWidthMM,length:c.truckLengthMM}:null;
    }
    if(id.startsWith('pallet:'))return pallets.get(id.slice(7))?.rect||null;
    if(id.startsWith('column:'))return columns[ids.get(id.slice(7))]?.rect||null;
    return null;
  }
  function adjacent(a,b,dir,mode,eggSide){
    let gap,spans;
    if(b.wall){
      if(b.wall!==dir)return false;
      if(dir==='left')gap=a.x;
      if(dir==='front')gap=a.y;
      if(dir==='right')gap=b.width-a.x-a.w;
      if(dir==='rear')gap=b.length-a.y-a.d;
      spans=true;
    }else if(dir==='left'||dir==='right'){
      gap=dir==='left'?a.x-b.x-b.w:b.x-a.x-a.w;
      spans=b.y<=a.y+EPS && b.y+b.d>=a.y+a.d-EPS;
    }else{
      gap=dir==='front'?a.y-b.y-b.d:b.y-a.y-a.d;
      spans=b.x<=a.x+EPS && b.x+b.w>=a.x+a.w-EPS;
    }
    return spans && gap>=-EPS && (mode==='contact'?Math.abs(gap)<EPS:gap<eggSide-EPS);
  }
  function heights(data,state){return state.map((col,i)=>col.reduce((n,g)=>n+g.quantity*unitHeight(data.config,data.lots[g.lot].kind),data.columns[i].base));}
  function supportTop(data,state,index){
    const col=data.columns[index];let top=col.base;
    for(const g of state[index]){
      const kind=data.lots[g.lot].kind;
      if(kind==='grainBox20'&&rice(col.kind)){
        const b=size(data.config,kind,false),r=col.rect;
        // A smaller box cannot extend the rice column's full supporting face.
        if(!((Math.abs(b.w-r.w)<EPS&&Math.abs(b.d-r.d)<EPS)||(Math.abs(b.d-r.w)<EPS&&Math.abs(b.w-r.d)<EPS)))break;
      }
      top+=g.quantity*unitHeight(data.config,kind);
    }
    return top;
  }
  function checkState(data,state,stationary){
    if(!Array.isArray(state)||state.length!==data.columns.length||state.some(col=>!Array.isArray(col)||col.some(g=>!validInt(g.lot,0,data.lots.length-1)||!validInt(g.quantity,1,20000))))return '현재 적재 위치·화물 묶음·수량을 확인해 주세요.';
    if(state.reduce((n,col)=>n+col.reduce((a,g)=>a+g.quantity,0),0)>20000)return '차량 내 화물 기록은 합계 20000개까지 지원합니다.';
    const hs=heights(data,state),c=data.config;
    for(let i=0;i<state.length;i++)if(state[i].length){
      const col=data.columns[i];
      if(col.temporaryFloor&&!stationary)return col.name+': 출발 전에 임시 바닥의 쌀을 파렛트 위로 옮겨야 합니다.';
      for(const g of state[i]){
        if(!compatible(col,data.lots[g.lot].kind))return col.name+': 이 자리에 놓을 수 없는 품목입니다.';
        if(data.lots[g.lot].kind==='grainBox20'){const b=size(c,'grainBox20',false),r=col.rect;if(!((b.w<=r.w+EPS&&b.d<=r.d+EPS)||(b.d<=r.w+EPS&&b.w<=r.d+EPS)))return col.name+': 박스 받침 면적이 부족합니다.';}
      }
      for(let j=i+1;j<state.length;j++)if(state[j].length&&overlap(col.rect,data.columns[j].rect))return col.name+': 다른 화물과 바닥 면적이 겹칩니다.';
    }
    for(const p of data.pallets.values()){
      const occupied=data.columns.filter((col,i)=>col.palletID===p.id&&state[i].some(g=>rice(data.lots[g.lot].kind)));
      const cap={rice20:5,rice10:8,rice4:15,bag25to40:6};
      if(occupied.length>(cap[occupied[0]?.kind]||Infinity))return p.name+': 한 층의 쌀 자리 수를 넘습니다.';
    }
    for(let i=0;i<state.length;i++){
      const col=data.columns[i],groups=state[i];
      if(hs[i]-col.base>col.maxHeightMM+EPS||hs[i]>c.truckHeightMM+EPS)return col.name+': 허용 높이를 넘습니다.';
      const bagLayers=groups.filter(g=>rice(data.lots[g.lot].kind)).reduce((n,g)=>n+g.quantity,0);
      if(layerLimits[col.kind] && bagLayers>layerLimits[col.kind])return col.name+': '+labels[col.kind]+' 최대 '+layerLimits[col.kind]+'층을 넘습니다.';
      for(const [kind,limit] of Object.entries(col.maxUnitsByKind||{}))if(groups.filter(g=>data.lots[g.lot].kind===kind).reduce((n,g)=>n+g.quantity,0)>limit)return col.name+': '+labels[kind]+' 지정 적층 한도 '+limit+'개를 넘습니다.';
      let boxBelow=false;
      for(const g of groups){const k=data.lots[g.lot].kind;if(rice(k)&&boxBelow)return col.name+': 곡류 박스 위에 쌀포대를 얹을 수 없습니다.';if(k==='grainBox20')boxBelow=true;}
      if(col.kind!=='eggTray'||!groups.length)continue;
      const count=groups.reduce((a,g)=>a+g.quantity,0),supported=[];
      for(const s of col.supports){
        if(!s.targetID)continue;
        let top=null;
        if(s.targetID.startsWith('wall:'))top=c.truckHeightMM;
        if(s.targetID.startsWith('pallet:'))top=c.palletHeightMM;
        if(s.targetID.startsWith('column:')){const j=data.columnIDs.get(s.targetID.slice(7));if(state[j]?.length || data.columns[j]?.base>0)top=supportTop(data,state,j);}
        if(top!==null && top>col.base && (count<=5||hs[i]-top<=5*c.eggTrayHeightMM+EPS))supported.push(s.direction);
      }
      if(count<=5 ? supported.length<1 : sides.some(s=>!supported.includes(s)))return col.name+': '+count+'판 계란의 '+(count<=5?'접촉 지지가 없습니다.':'사방 지지 또는 지지 높이가 부족합니다.');
    }
    return null;
  }
  function accessReason(data,state,column,operation,kind){
    const col=data.columns[column];
    const hs=col.accessSource==='geometry'?heights(data,state):null;
    const bottom=hs?hs[column]-(operation==='unload'?unitHeight(data.config,kind):0):0;
    if(hs && bottom+EPS<col.accessMinimumHeightMM)return col.name+': 빈 파렛트가 이 높이의 수평 통로를 막습니다.';
    for(const id of col.blockedByIDs){const i=data.columnIDs.get(id);if(state[i].length && (!hs||hs[i]>bottom+EPS))return col.name+': '+data.columns[i].name+'의 화물이 하역 통로를 막습니다.';}
    return null;
  }
  function fixedTransition(data,state,visitID,options){
    if(!data.enabled)return {ok:true,state,actions:[],limited:false};
    const targets=options?.taskQuantities || data.taskQuantities;
    const cacheKey=JSON.stringify([visitID,stateKey(state),targets||null]);
    if(data.cache.has(cacheKey))return data.cache.get(cacheKey);
    const opt=options||{},maxNodes=opt.maxNodes||12000,began=Date.now(),maxMs=opt.maxMilliseconds||300;
    const quantity=(l,op)=>targets ? (targets[l.id]?.[op] ?? l.quantity) : l.quantity;
    const unload=data.lots.filter(l=>l.unloadAt===visitID).map(l=>({...l,quantity:quantity(l,'unload')})).filter(l=>l.quantity>0);
    const load=data.lots.filter(l=>l.loadAt===visitID).map(l=>({...l,quantity:quantity(l,'load')})).filter(l=>l.quantity>0).sort((a,b)=>a.stackOrder-b.stackOrder);
    for(const l of unload){
      const available=state[l.column].filter(g=>g.lot===l.index).reduce((a,g)=>a+g.quantity,0);
      if(targets ? available<l.quantity : available!==l.quantity)return remember({ok:false,reason:'앞선 장소에서 실어야 할 '+labels[l.kind]+'이 아직 없습니다.',limited:false});
    }
    const tasks=[...unload.map(l=>({lot:l,op:'unload'})),...load.map(l=>({lot:l,op:'load'}))];
    const total=tasks.reduce((n,t)=>n+t.lot.quantity,0);
    if(!total)return remember({ok:true,state,actions:[],limited:false});
    let examined=0,lastReason='다른 화물이 위에 있어 필요한 물건을 꺼낼 수 없습니다.';
    const seen=new Set(),frames=[{state,done:tasks.map(()=>0),actions:[],next:0}];
    while(frames.length){
      if(++examined>maxNodes||Date.now()-began>maxMs)return remember({ok:false,reason:'이 거래처의 상하차 작업 순서 탐색 한도에 도달했습니다.',limited:true});
      const frame=frames[frames.length-1];
      if(frame.done.every((n,i)=>n===tasks[i].lot.quantity))return remember({ok:true,state:frame.state,actions:compact(frame.actions),limited:false});
      let advanced=false;
      for(let i=frame.next;i<tasks.length;i++){
        frame.next=i+1;
        const task=tasks[i],lot=task.lot,remaining=lot.quantity-frame.done[i];
        if(!remaining)continue;
        const col=frame.state[lot.column],top=col[col.length-1];
        if(task.op==='unload' && (!top || top.lot!==lot.index)){
          if(top)lastReason=data.columns[lot.column].name+': '+(data.lots[top.lot].unloadAt==='depot'?'회사로 가져갈 매입품':'다른 거래처 화물')+'이 '+labels[lot.kind]+' 위를 덮고 있습니다.';
          continue;
        }
        if(task.op==='load' && tasks.some((other,j)=>other.op==='load'&&other.lot.column===lot.column&&other.lot.stackOrder<lot.stackOrder&&frame.done[j]<other.lot.quantity))continue;
        const blocked=accessReason(data,frame.state,lot.column,task.op,lot.kind);
        if(blocked){lastReason=blocked;continue;}
        const quantity=data.hasEggs||data.hasGeometryAccess?1:(task.op==='unload'?Math.min(remaining,top.quantity):remaining),next=clone(frame.state),groups=next[lot.column];
        if(task.op==='unload'){groups[groups.length-1].quantity-=quantity;if(!groups[groups.length-1].quantity)groups.pop();}
        else if(groups.length&&groups[groups.length-1].lot===lot.index)groups[groups.length-1].quantity+=quantity;
        else groups.push({lot:lot.index,quantity});
        const failure=checkState(data,next);
        if(failure){lastReason=failure;continue;}
        const done=frame.done.slice();done[i]+=quantity;
        const k=done.join(',');if(seen.has(k))continue;seen.add(k);
        frames.push({state:next,done,actions:frame.actions.concat({lotID:lot.id,columnID:lot.columnID,kind:lot.kind,operation:task.op,quantity}),next:0});advanced=true;break;
      }
      if(!advanced)frames.pop();
    }
    return remember({ok:false,reason:lastReason,limited:false});
    function remember(value){if(!value.limited && data.cache.size<4000)data.cache.set(cacheKey,value);return value;}
  }
  function compatible(col,kind){return col.kind===kind||(kind==='grainBox20'&&rice(col.kind));}
  function move(data,state,action,stationary) {
    if(!data.enabled)return {ok:false,reason:'적재 배치가 필요합니다.'};
    const lot=data.lots.find(l=>l.id===action.lotID),relocate=action.operation==='relocate';
    if(!lot||!['load','unload','relocate'].includes(action.operation)||!validInt(action.quantity,1,20000))return {ok:false,reason:'화물 묶음·작업·수량을 확인해 주세요.'};
    const source=relocate?data.columnIDs.get(action.fromColumnID):data.columnIDs.get(action.columnID||lot.columnID);
    const target=relocate?data.columnIDs.get(action.toColumnID):source;
    if(source===undefined||target===undefined||(relocate&&source===target)||!compatible(data.columns[target],lot.kind))return {ok:false,reason:'옮길 출발·도착 자리와 품목을 확인해 주세요.'};
    let next=clone(state);
    for(let unit=0;unit<action.quantity;unit++){
      if(action.operation!=='load'){
        const col=next[source],top=col[col.length-1];
        if(!top||top.lot!==lot.index)return {ok:false,reason:data.columns[source].name+': 위에 있는 화물부터 내려야 합니다.'};
        const blocked=accessReason(data,next,source,'unload',lot.kind);if(blocked)return {ok:false,reason:blocked};
        top.quantity--;if(!top.quantity)col.pop();
        const failure=checkState(data,next,stationary);if(failure)return {ok:false,reason:failure};
      }
      if(action.operation!=='unload'){
        const blocked=accessReason(data,next,target,'load',lot.kind);if(blocked)return {ok:false,reason:blocked};
        const col=next[target],top=col[col.length-1];
        if(top?.lot===lot.index)top.quantity++;else col.push({lot:lot.index,quantity:1});
        const failure=checkState(data,next,stationary);if(failure)return {ok:false,reason:failure};
      }
    }
    return {ok:true,state:next,action:{...action,columnID:data.columns[target].id,kind:lot.kind}};
  }
  function transition(data,state,visitID,options){
    if(!data.enabled)return {ok:true,state,actions:[],limited:false,extraMinutes:0};
    const moved=state.some((col,i)=>col.some(g=>data.lots[g.lot].column!==i));
    const settings=data.config.rehandling||{},enabled=settings.enabled===true;
    let fast=moved?{ok:false,reason:'현재 자리에서 필요한 화물을 찾습니다.',limited:false}:fixedTransition(data,state,visitID,options);
    if(fast.ok)return {...fast,extraMinutes:0};
    if(!enabled&&!moved)return fast;
    const targets=options?.taskQuantities||data.taskQuantities;
    const cacheKey=JSON.stringify(['flex',visitID,stateKey(state),targets||null]);
    if(data.cache.has(cacheKey))return data.cache.get(cacheKey);
    const desired=(l,op)=>targets?.[l.id]?.[op]??l.quantity;
    const tasks=[];
    for(const l of data.lots){
      if(l.unloadAt===visitID&&desired(l,'unload')>0)tasks.push({lot:l,op:'unload',quantity:desired(l,'unload')});
      if(l.loadAt===visitID&&desired(l,'load')>0)tasks.push({lot:l,op:'load',quantity:desired(l,'load')});
    }
    const present=l=>state.reduce((n,col)=>n+col.filter(g=>g.lot===l.index).reduce((m,g)=>m+g.quantity,0),0);
    if(tasks.some(t=>t.op==='unload'&&present(t.lot)<t.quantity))return {ok:false,reason:'배송할 실제 화물이 부족합니다. 남은 주문 수량과 매입 기록을 확인해 주세요.',limited:false};
    const maxMoved=enabled?(validInt(settings.maxMovedUnits,1,40)?settings.maxMovedUnits:12):0;
    const seconds=validInt(settings.secondsPerUnit,1,3600)?settings.secondsPerUnit:60;
    const setup=validInt(settings.setupMinutes,0,60)?settings.setupMinutes:0;
    const maxNodes=options?.maxNodes||2500,maxMs=options?.maxMilliseconds||400,began=Date.now();
    const queue=[{state,done:tasks.map(()=>0),actions:[],moved:0}],seen=new Map();let examined=0,lastReason=fast.reason,pruned=false;
    while(queue.length){
      if(++examined>maxNodes||Date.now()-began>maxMs)return {ok:false,reason:'재배치 작업 탐색 한도에 도달했습니다.',limited:true};
      queue.sort((a,b)=>a.moved-b.moved||b.done.reduce((x,y)=>x+y,0)-a.done.reduce((x,y)=>x+y,0));
      if(queue.length>2000){queue.length=2000;pruned=true;}
      const frame=queue.shift(),key=JSON.stringify([stateKey(frame.state),frame.done]);
      if(seen.has(key)&&seen.get(key)<=frame.moved)continue;seen.set(key,frame.moved);
      if(frame.done.every((n,i)=>n===tasks[i].quantity)&&!checkState(data,frame.state)){
        const result={ok:true,state:frame.state,actions:compact(frame.actions),limited:pruned,movedUnits:frame.moved,extraMinutes:frame.moved?setup+Math.ceil(frame.moved*seconds/60):0};
        if(data.cache.size<4000)data.cache.set(cacheKey,result);return result;
      }
      function attempt(action,taskIndex){
        const step=move(data,frame.state,action,true);if(!step.ok){lastReason=step.reason;return;}
        const done=frame.done.slice();if(taskIndex!==null)done[taskIndex]++;
        queue.push({state:step.state,done,actions:frame.actions.concat(step.action),moved:frame.moved+(action.operation==='relocate'?1:0)});
      }
      tasks.forEach((task,index)=>{
        if(frame.done[index]>=task.quantity)return;
        if(task.op==='unload')frame.state.forEach((col,i)=>{if(col[col.length-1]?.lot===task.lot.index)attempt({lotID:task.lot.id,columnID:data.columns[i].id,operation:'unload',quantity:1},index);});
        else attempt({lotID:task.lot.id,columnID:task.lot.columnID,operation:'load',quantity:1},index);
      });
      if(frame.moved<maxMoved)frame.state.forEach((col,i)=>{
        const top=col[col.length-1];if(!top)return;const lot=data.lots[top.lot];
        data.columns.forEach((dest,j)=>{if(i!==j&&compatible(dest,lot.kind))attempt({lotID:lot.id,fromColumnID:data.columns[i].id,toColumnID:dest.id,operation:'relocate',quantity:1},null);});
      });
    }
    return {ok:false,reason:lastReason||'등록한 빈자리와 통로에서 재배치 방법을 찾지 못했습니다.',limited:pruned};
  }
  function compact(actions){
    const out=[];
    for(const action of actions){const p=out[out.length-1];if(p&&p.lotID===action.lotID&&p.operation===action.operation&&p.columnID===action.columnID&&p.fromColumnID===action.fromColumnID&&p.toColumnID===action.toColumnID)p.quantity+=action.quantity;else out.push({...action});}
    return out;
  }
  function snapshot(data,state,visitID,actions){
    const hs=heights(data,state),inventory=kinds.map(kind=>({kind,quantity:state.reduce((n,col)=>n+col.filter(g=>data.lots[g.lot].kind===kind).reduce((s,g)=>s+g.quantity,0),0)}));
    const columns=data.columns.map((col,i)=>({id:col.id,name:col.name,kind:col.kind,xMM:col.rect.x,yMM:col.rect.y,widthMM:col.rect.w,depthMM:col.rect.d,heightMM:hs[i],quantity:state[i].reduce((n,g)=>n+g.quantity,0),remainingHeightMM:col.maxHeightMM-(hs[i]-col.base),lots:state[i].map(g=>({lotID:data.lots[g.lot].id,kind:data.lots[g.lot].kind,quantity:g.quantity,unloadAt:data.completedIDs?.has(data.lots[g.lot].unloadAt)?'depot':data.lots[g.lot].unloadAt}))}));
    // No capacity percentage: free height is not additional feasible cargo.
    return {visitID,inventory,columns,actions};
  }
  function trace(data,path,initialState,startID){
    if(!data.enabled)return null;
    let state=initialState||data.initial;const snapshots=[snapshot(data,state,startID||'depot',[])];
    for(const visitID of path){const step=transition(data,state,visitID);if(!step.ok)throw Error('검증한 적재 상태를 복원하지 못했습니다.');state=step.state;snapshots.push(snapshot(data,state,visitID,step.actions));}
    return {scope:'registered_pattern',palletCount:data.pallets.size,truckWidthMM:data.config.truckWidthMM,truckLengthMM:data.config.truckLengthMM,snapshots};
  }
  return {prepare,transition,trace,move,snapshot,checkState,compatible,size,labels,stateKey,unitHeight,adjacent,overlap,inside,kinds,deriveAccess};
})();
if(typeof module!=='undefined'&&module.exports)module.exports=DeliveryCargo;
