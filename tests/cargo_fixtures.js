'use strict';
const kinds=['rice20','rice10','rice4','bag25to40','grainBox20','eggTray'];
const labels={rice20:'쌀 20kg 포대',rice10:'쌀 10kg 포대',rice4:'쌀 4kg 낱포대',bag25to40:'25~40kg 포대',grainBox20:'곡류 20kg 박스',eggTray:'계란 판'};
function visit(id,orders={}){return {id,name:id,kind:'delivery',serviceMinutes:5,maxWaitMinutes:0,allowEarlyArrival:true,canRestHere:true,fixedPosition:0,minPosition:1,maxPosition:30,afterIDs:[],immediatelyAfterID:'',arrivalWindowsText:'',avoidWindowsText:'',orders:kinds.map(kind=>({id:kind,label:labels[kind],deliver:orders[kind]?.deliver||0,pickup:orders[kind]?.pickup||0})),note:'가상 시험 거래처'};}
function config(){return {enabled:true,truckWidthMM:1600,truckLengthMM:2800,truckHeightMM:2000,palletSideMM:1200,palletHeightMM:150,rice20HeightMM:100,rice10WidthMM:300,rice10HeightMM:80,rice4HeightMM:60,bulkBagWidthMM:400,bulkBagDepthMM:600,bulkBagHeightMM:150,eggSideMM:270,eggTrayHeightMM:50,boxWidthMM:270,boxDepthMM:270,boxHeightMM:100,pallets:[{id:'p1',name:'앞 파렛트',xMM:0,yMM:0}],columns:[],lots:[]};}
function column(id,kind,x,y,palletID='',extra={}){return {id,name:id,kind,xMM:x,yMM:y,rotated:false,palletID,maxHeightMM:1000,accessConfirmed:true,blockedByIDs:[],supports:['left','right','front','rear'].map(direction=>({direction,targetID:'',mode:'contact'})),...extra};}
function lot(id,columnID,kind,quantity,loadAt,unloadAt,stackOrder=1){return {id,columnID,kind,quantity,loadAt,unloadAt,stackOrder};}
function plan(visits,cargo){const ids=['depot',...visits.map(v=>v.id)],legs=[];for(const a of ids)for(const b of ids)if(a!==b)legs.push({id:a+'-'+b,fromID:a,toID:b,minutes:5,source:'demo',note:'가상 이동시간'});return {schemaVersion:3,planDate:'2026-09-19',originName:'맑은아침농산',startMinute:480,originWaitMinutes:0,returnToOrigin:true,visits,legs,cargo};}
function rice100(){
  const c=config();c.pallets.push({id:'p2',name:'뒤 파렛트',xMM:0,yMM:1200});
  for(let i=0;i<10;i++){
    const slot=i%5,pallet=i<5?'p1':'p2',id='쌀자리 '+(i+1);
    c.columns.push(column(id,'rice20',(slot%3)*400,Math.floor(slot/3)*600+(i<5?0:1200),pallet));
    c.lots.push(lot('bottom'+i,id,'rice20',7,'depot','B 70포 배송',1),lot('top'+i,id,'rice20',3,'depot','A 30포 배송',2),lot('pickup'+i,id,'rice20',3,'C 30포 매입','depot',1));
  }
  const p=plan([visit('A 30포 배송',{rice20:{deliver:30}}),visit('B 70포 배송',{rice20:{deliver:70}}),visit('C 30포 매입',{rice20:{pickup:30}})],c);
  p.visits[2].kind='pickup';
  for(const l of p.legs)l.minutes=(l.fromID==='A 30포 배송'&&l.toID==='C 30포 매입')||(l.fromID==='C 30포 매입'&&l.toID==='B 70포 배송')?1:5;
  return p;
}
function eggs(){
  const c=config();
  c.columns.push(column('받침 쌀','rice20',800,0,'p1'),column('계란','eggTray',1200,0),column('받침 박스','grainBox20',1200,270));
  c.columns[1].supports=[{direction:'left',targetID:'column:받침 쌀',mode:'contact'},{direction:'right',targetID:'wall:right',mode:'narrow'},{direction:'front',targetID:'wall:front',mode:'contact'},{direction:'rear',targetID:'column:받침 박스',mode:'contact'}];
  c.lots.push(lot('rice','받침 쌀','rice20',5,'depot','B 쌀·박스 배송'),lot('eggs','계란','eggTray',10,'depot','A 계란 배송'),lot('box','받침 박스','grainBox20',6,'depot','B 쌀·박스 배송'));
  const p=plan([visit('A 계란 배송',{eggTray:{deliver:10}}),visit('B 쌀·박스 배송',{rice20:{deliver:5},grainBox20:{deliver:6}})],c);
  p.legs.find(l=>l.fromID==='depot'&&l.toID==='B 쌀·박스 배송').minutes=1;
  return p;
}
function thirty(){
  const c=config(),vs=[];
  for(let i=0;i<5;i++)c.columns.push(column('R'+i,'rice20',i%3*400,Math.floor(i/3)*600,'p1'));
  for(let i=0;i<30;i++){const id='배송 '+String(i+1).padStart(2,'0');vs.push(visit(id,{rice20:{deliver:1}}));vs[i].serviceMinutes=1;c.lots.push(lot('L'+i,'R'+i%5,'rice20',1,'depot',id,30-i));}
  return plan(vs,c);
}
module.exports={visit,config,column,lot,plan,rice100,eggs,thirty};
