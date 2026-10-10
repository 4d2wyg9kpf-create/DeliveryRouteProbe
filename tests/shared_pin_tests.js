'use strict';
const assert=require('node:assert/strict'),places=require('../scripts/naver_places'),api=require('../scripts/naver_api');
const checks=[],copy=x=>JSON.parse(JSON.stringify(x)),now=Date.parse('2026-10-09T14:50:00Z');
function test(name,fn){try{fn();checks.push({name,passed:true});}catch(e){checks.push({name,passed:false,error:e.message});}}
function point(longitude=127.4,url='https://naver.me/pointA'){
  const c=api.seed({name:'가상 공유 지점',address:'대전 중구 가상로 1',now}),latitude=36.3;
  c.coordinate={longitude,latitude};c.tileZoom=18;c.screenResolutionMeters=1;c.method='rendered_selected_marker_and_tiles';c.coordinateIssue='';
  c.point={name:c.name,token:[(longitude/180*20037508.342789244).toFixed(3),(6378137*Math.log(Math.tan(Math.PI/4+latitude*Math.PI/360))).toFixed(3),encodeURIComponent(c.name),'','SIMPLE_POI'].join(',')};
  return places.shared({capture:c,url});
}
test('selected shared coordinate and complete original link are retained',()=>{const c=point();assert.equal(c.coordinate.longitude,127.4);assert.equal(c.sharedLinkURL,'https://naver.me/pointA');});
test('same-address pins with different coordinates do not match',()=>{assert(!places.customerMatches({first:point(),second:point(127.4001,'https://naver.me/pointB')}));});
test('coordinate differences smaller than one metre remain separate',()=>{assert(!places.customerMatches({first:point(),second:point(127.4000002,'https://naver.me/pointB')}));});
test('regenerated short links for the same selected point match',()=>{assert(places.customerMatches({first:point(),second:point(127.4,'https://naver.me/pointAgain')}));});
test('API building coordinates cannot replace a shared address point',()=>{const c=point();assert.throws(()=>api.geocode({capture:c,response:{status:'OK',addresses:[{roadAddress:c.address,jibunAddress:'',x:'127.4',y:'36.3'}]}}));});
test('adding shared provenance to an API-derived address coordinate is rejected',()=>{const seed=api.seed({name:'가상 공유 지점',address:'대전 중구 가상로 1',now}),c=api.geocode({capture:seed,response:{status:'OK',addresses:[{roadAddress:seed.address,jibunAddress:'',x:'127.4',y:'36.3'}]}});assert.throws(()=>places.shared({capture:c,url:'https://naver.me/pointA'}));});
test('missing selected point stays unsaveable with a specific explanation',()=>{const c=places.shared({capture:api.seed({name:'가상 공유 지점',address:'대전 중구 가상로 1',now}),url:'https://naver.me/pointA'});assert.equal(c.coordinate,null);assert.match(c.coordinateIssue,/대표 좌표로 대신 저장하지/);});
test('unrelated URL cannot be recorded as NAVER shared provenance',()=>{const c=point();delete c.sharedLinkURL;assert.throws(()=>places.shared({capture:c,url:'https://map.naver.com.evil.test/p/search/주소'}));});
test('legacy capture without shared provenance remains readable',()=>{const c=point();delete c.sharedLinkURL;assert.equal(places.validate(c).coordinate.longitude,127.4);});
test('point token tampering is still rejected for shared coordinates',()=>{const c=copy(point());c.coordinate.longitude+=.001;assert.throws(()=>places.validate(c));});
test('native JSON bridge exposes the same shared-pin validation',()=>{const c=point();delete c.sharedLinkURL;const r=JSON.parse(places.sharedJSON(JSON.stringify({capture:c,url:'https://naver.me/pointA'})));assert(r.ok);assert.equal(r.value.coordinate.longitude,127.4);assert.equal(r.value.sharedLinkURL,'https://naver.me/pointA');});
test('selection verification rejects another pin at the same address',()=>{assert(!places.sameSelection({capture:point(),fresh:point(127.4000002,'https://naver.me/pointB'),useCoordinate:false}).same);});
function customers(){return [point(),point(127.4000002,'https://naver.me/pointB')].map((c,i)=>({id:'customer-'+i,name:c.name,capture:c,template:{id:'visit-'+i,name:c.name,naverPlace:c}}));}
function deliveries(selectedIDs=['customer-0','customer-1'],plan={visits:[],legs:[]}){return places.selectCustomers({plan,customers:customers(),selectedIDs,curbConfirmed:true});}
test('both same-address shared pins can be selected as separate delivery visits',()=>{const p=deliveries();assert.equal(p.visits.length,2);assert.deepEqual(p.visits.map(v=>v.tmapCoordinate.longitude),[127.4,127.4000002]);});
test('unchecking one point retains the other same-address delivery visit',()=>{const p=deliveries(['customer-1'],deliveries());assert.equal(p.visits.length,1);assert.equal(p.visits[0].id,'visit-1');assert.equal(p.visits[0].tmapCoordinate.longitude,127.4000002);});
test('replacing a selected pin does not retain another nearby point coordinate',()=>{const c=point(127.4000002,'https://naver.me/pointB'),r=places.attach({plan:deliveries(['customer-0']),capture:c,targetID:'visit-0',useCoordinate:true,curbConfirmed:true,requestAddress:c.address});assert.equal(r.plan.visits[0].tmapCoordinate.longitude,127.4000002);});
console.log(JSON.stringify({passed:checks.filter(c=>c.passed).length,total:checks.length,checks}));
if(checks.some(c=>!c.passed))process.exitCode=1;
