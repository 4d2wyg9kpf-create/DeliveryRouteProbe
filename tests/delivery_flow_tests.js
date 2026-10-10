'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const tmap=require('../scripts/tmap.js');
const planner=require('../scripts/planner.js');
const now=Date.parse('2026-10-09T10:00:00+09:00');
const checks=[];
function test(name,run){run();checks.push({name,passed:true});}
function makePlan(){return {schemaVersion:3,planDate:'2026-10-09',originName:'가상 출발지',startMinute:480,originWaitMinutes:0,returnToOrigin:true,
  tmapOrigin:{longitude:127.39,latitude:36.31},legs:[],cargo:{enabled:false},visits:Array.from({length:9},(_,i)=>({id:'fixture-'+i,name:'가상 배송지 '+(i+1),kind:'delivery',serviceMinutes:5,
  maxWaitMinutes:0,allowEarlyArrival:true,canRestHere:false,fixedPosition:0,minPosition:1,maxPosition:30,afterIDs:[],immediatelyAfterID:'',arrivalWindowsText:'',avoidWindowsText:'',orders:[],note:'',
  tmapCoordinate:{longitude:127.4,latitude:36.3}}))};}
function apiResult(plan,request){
  const stamp=minute=>'20261009'+String(Math.floor(minute/60)).padStart(2,'0')+String(minute%60).padStart(2,'0')+'00';
  function feature(index,wire,type,line){return {type:'Feature',geometry:line?{type:'LineString',coordinates:[[127.39,36.31],[127.4,36.3]]}:{type:'Point',coordinates:[127.4,36.3]},
    properties:{index:String(index),viaPointId:wire,pointType:type,arriveTime:stamp(480+index*7),completeTime:stamp(480+index*7+(type==='E'?0:5)),distance:'1000',...(line?{time:'120',Fare:'0'}:{})}};}
  const features=[feature(0,'','S',false)];
  for(let i=1;i<=plan.visits.length;i++){const wire=String(plan.visits.length-i+1);features.push(feature(i,wire,'B'+i,false),feature(i,wire,'B'+i,true));}
  const end=plan.visits.length+1;features.push(feature(end,'','E',false),feature(end,'','E',true));
  return tmap.parse({response:{type:'FeatureCollection',features},request,plan,now});
}
function solve(plan){const original=Date.now;Date.now=()=>now;try{return planner.solve(plan);}finally{Date.now=original;}}
test('Nine selected deliveries with zero manual legs receive a complete TMap route and validated result',()=>{
  const plan=makePlan(),request=tmap.request({plan,options:{searchOption:'2',truckRouting:false}});
  assert.equal(plan.legs.length,0);assert.equal(JSON.parse(request.body).viaPoints.length,9);
  const route=apiResult(plan,request);assert.equal(route.rows.length,10);assert.equal(route.legs.length,10);
  const connected=tmap.apply({plan,route,now}),result=solve(connected);
  assert.equal(result.status,'candidate');assert.equal(result.rows.length,9);assert.equal(result.totalTravelMinutes,20);
  assert.deepEqual(result.rows.map(v=>v.visitID),plan.visits.map(v=>v.id).reverse());assert.equal(result.returnMinutes,2);
});
test('Earlier manual/Naver alternatives cannot replace the TMap route order or travel times',()=>{
  const plan=makePlan(),request=tmap.request({plan,options:{searchOption:'2',truckRouting:false}}),route=apiResult(plan,request);
  plan.legs.push({id:'fixture-manual',fromID:'depot',toID:'fixture-8',minutes:0,source:'manual',note:''});
  const connected=tmap.apply({plan,route,now}),result=solve(connected);
  assert.equal(result.status,'candidate');assert.equal(result.rows[0].travelMinutes,2);assert.equal(result.rows[0].legID,route.legs[0].id);
  assert.ok(connected.legs.some(v=>v.id==='fixture-manual'));assert.deepEqual(connected.tmapBinding.visitIDs,plan.visits.map(v=>v.id).reverse());
});
test('Delivery window violations remain visible while received provider route data remains available',()=>{
  const plan=makePlan();plan.visits[8].arrivalWindowsText='06:00-06:30';
  const request=tmap.request({plan,options:{searchOption:'2',truckRouting:false}}),route=apiResult(plan,request),connected=tmap.apply({plan,route,now});
  assert.notEqual(solve(connected).status,'candidate');assert.equal(route.rows.length,10);assert.equal(route.paths.length,10);
  assert.equal(connected.visits[8].arrivalWindowsText,'06:00-06:30');assert.equal(plan.legs.length,0);
});
const report={passed:checks.length,total:checks.length,checks,liveAPI:false};
const evidence=path.join(__dirname,'../evidence');if(fs.existsSync(evidence))fs.writeFileSync(path.join(evidence,'delivery_flow_tests.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report));
