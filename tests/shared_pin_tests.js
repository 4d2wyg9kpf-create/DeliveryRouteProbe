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
test('same-address pins with different coordinates are duplicate saves',()=>{assert(places.customerMatches({first:point(),second:point(127.4001,'https://naver.me/pointB')}));});
test('address equality also identifies duplicates for a small coordinate difference',()=>{assert(places.customerMatches({first:point(),second:point(127.4000002,'https://naver.me/pointB')}));});
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
test('different share labels at the same address still count as duplicates',()=>{const b=point(127.4001,'https://naver.me/pointB');b.name='다른 공유 이름';assert(places.customerMatches({first:point(),second:b}));});
test('different building numbers do not count as duplicate addresses',()=>{const b=point();b.address=b.roadAddress='대전 중구 가상로 1-1';assert(!places.customerMatches({first:point(),second:b}));});
test('replacing a selected pin does not retain another nearby point coordinate',()=>{const c=point(127.4000002,'https://naver.me/pointB'),r=places.attach({plan:deliveries(['customer-0']),capture:c,targetID:'visit-0',useCoordinate:true,curbConfirmed:true,requestAddress:c.address});assert.equal(r.plan.visits[0].tmapCoordinate.longitude,127.4000002);});
// Synthetic HTTP redirect fixtures. Never commit a user's share token/address.
function redirectPin(changes={},extra=''){
  const fields={appMenu:'location',menu:'location',address:'대전 중구 가상로 1',title:'대전 중구 가상로 1',query:'대전 중구 가상로 1',lng:'127.4000001',lat:'36.3000001',...changes};
  const resolvedURL='https://map.naver.com/?'+Object.entries(fields).filter(([,v])=>v!=null).map(([k,v])=>encodeURIComponent(k)+'='+encodeURIComponent(v)).join('&')+extra;
  return places.sharedPin({resolvedURL,sharedURL:'https://naver.me/fixture1',now});
}
test('HTTP location redirect preserves full precision coordinates',()=>{const c=redirectPin();assert.equal(c.coordinate.longitude,127.4000001);assert.equal(c.coordinate.latitude,36.3000001);assert.equal(c.method,'naver_shared_link_coordinate');});
test('HTTP location redirect retains original token and resolved evidence',()=>{const c=redirectPin();assert.equal(c.sharedLinkURL,'https://naver.me/fixture1');assert.equal(c.sharedPinEvidence.longitude,'127.4000001');assert.equal(c.sourceURL,c.sharedPinEvidence.resolvedURL);});
test('HTTP pin address comes from its response rather than the pasted title',()=>{assert.equal(redirectPin().address,'대전 중구 가상로 1');});
test('map center parameter never overrides explicit shared pin',()=>{assert.equal(redirectPin({},'&c=0,0,0,0,dh').coordinate.longitude,127.4000001);});
test('same building retains each HTTP pin and fails selection verification after a change',()=>{const a=redirectPin(),b=redirectPin({lng:'127.4000002'});assert(places.customerMatches({first:a,second:b}));assert(!places.sameSelection({capture:a,fresh:b,useCoordinate:false}).same);assert.equal(b.coordinate.longitude,127.4000002);});
test('HTTP pins cannot be replaced by API building coordinates',()=>{assert.throws(()=>api.geocode({capture:redirectPin(),response:{status:'OK',addresses:[{roadAddress:'대전 중구 가상로 1',jibunAddress:'',x:'127.4',y:'36.3'}]}}));});
test('HTTP coordinates without explicit location share are rejected',()=>{assert.throws(()=>redirectPin({appMenu:null,menu:null}));});
test('conflicting share menus are rejected',()=>{assert.throws(()=>redirectPin({menu:'search'}));});
test('duplicate longitude and encoded duplicate latitude are rejected',()=>{assert.throws(()=>redirectPin({},'&lng=127.5'));assert.throws(()=>redirectPin({},'&%6cat=36.4'));});
test('nonfinite, scientific, out of country and missing coordinates are rejected',()=>{for(const lng of ['NaN','1.274e2','200','',null])assert.throws(()=>redirectPin({lng}));});
test('ambiguous or missing address labels are rejected',()=>{assert.throws(()=>redirectPin({address:null}));assert.throws(()=>redirectPin({query:'대전 중구 가상로 2'}));assert.throws(()=>redirectPin({},'&address=other'));});
test('malformed escaped query content is rejected',()=>{assert.throws(()=>redirectPin({},'&title=%ZZ'));});
test('HTTP source must be the exact HTTPS NAVER map location URL',()=>{const c=redirectPin();for(const bad of ['https://map.naver.com.evil.test/?','http://map.naver.com/?','https://user@map.naver.com/?','https://map.naver.com:443/?'])assert.throws(()=>places.sharedPin({resolvedURL:c.sourceURL.replace('https://map.naver.com/?',bad),sharedURL:c.sharedLinkURL,now}));});
test('mutating HTTP evidence or coordinate invalidates a saved capture',()=>{for(const mutate of [c=>c.coordinate.longitude+=.00001,c=>c.sharedPinEvidence.longitude='127.5',c=>c.sourceURL='https://map.naver.com/p/search/other',c=>c.address='대전 중구 가상로 2',c=>delete c.sharedPinEvidence,c=>delete c.sharedLinkURL]){const c=redirectPin();mutate(c);assert.throws(()=>places.validate(c));}});
test('HTTP bridge produces a native JSON-compatible capture',()=>{const c=redirectPin(),r=JSON.parse(places.sharedPinJSON(JSON.stringify({resolvedURL:c.sourceURL,sharedURL:c.sharedLinkURL,now})));assert(r.ok);assert.equal(r.value.coordinate.longitude,c.coordinate.longitude);});
function sitePin(changes={},metadata={},extra=''){
  const fields={pinId:'101',pinType:'site',menu:'location',appMenu:'location',title:'가상식당 가상점',lng:'127.4000001',lat:'36.3000001',...changes};
  const resolvedURL='https://map.naver.com/?'+Object.entries(fields).filter(([,v])=>v!=null).map(([k,v])=>encodeURIComponent(k)+'='+encodeURIComponent(v)).join('&')+extra;
  return places.sharedPin({resolvedURL,sharedURL:'https://naver.me/fixtureSite',now,...metadata});
}
test('named site without address is readable and preserves selected coordinate',()=>{const c=sitePin();assert.equal(c.kind,'place');assert.equal(c.placeID,'101');assert.equal(c.selectionKey,'place:101');assert.equal(c.name,'가상식당 가상점');assert.equal(c.address,'');assert.equal(c.coordinate.longitude,127.4000001);assert.equal(c.sourceURL,'https://map.naver.com/p/entry/place/101');});
test('business share address fills metadata while coordinates only come from HTTP',()=>{const c=sitePin({},{sharedName:'가상식당 가상점',sharedAddress:'대전 유성구 가상로 11'});assert.equal(c.address,'대전 유성구 가상로 11');assert.equal(c.coordinate.latitude,36.3000001);assert.equal(c.sharedPinEvidence.sharedAddress,c.address);});
test('explicit response address takes precedence over pasted address label',()=>{const c=sitePin({address:'대전 유성구 가상로 11'},{sharedAddress:'대전 중구 다른로 9'});assert.equal(c.address,'대전 유성구 가상로 11');assert.equal(c.sharedPinEvidence.sharedAddress,undefined);});
test('another pasted business name cannot attach its address to the selected site',()=>{assert.throws(()=>sitePin({},{sharedName:'다른 식당',sharedAddress:'대전 유성구 가상로 11'}),/업체 이름/);});
test('site with missing, malformed or oversized identity is rejected',()=>{for(const pinId of [null,'','bad','1'.repeat(21)])assert.throws(()=>sitePin({pinId}));});
test('duplicate site identity or type cannot be selected ambiguously',()=>{assert.throws(()=>sitePin({},{},'&pinId=102'));assert.throws(()=>sitePin({},{},'&pinType=site'));});
test('site queries may name a business rather than repeat a road address',()=>{assert.equal(sitePin({query:'가상식당 가상점'}).placeID,'101');});
test('site evidence survives native-shaped JSON save and reload',()=>{const c=sitePin({},{sharedName:'가상식당 가상점',sharedAddress:'대전 유성구 가상로 11'});assert.deepEqual(places.validate(copy(c)),c);});
test('same site with changed selected coordinate fails revalidation even without coordinate attachment',()=>{const a=sitePin(),b=sitePin({lng:'127.4000002'});assert(!places.sameSelection({capture:a,fresh:b,useCoordinate:false}).same);});
test('site HTTP coordinates cannot be replaced by building geocoding',()=>{const c=sitePin({},{sharedAddress:'대전 유성구 가상로 11'});assert.throws(()=>api.geocode({capture:c,response:{status:'OK',addresses:[{roadAddress:c.address,jibunAddress:'',x:'127.4',y:'36.3'}]}}));assert.throws(()=>places.geocode({capture:c,candidates:[{countryCode:'KR',address:c.address,coordinate:{longitude:127.4,latitude:36.3}}]}));});
test('tampered site identity, coordinates or erased pin evidence are rejected',()=>{for(const mutate of [c=>c.placeID='102',c=>c.coordinate.latitude+=.00001,c=>c.coordinate=null,c=>delete c.sharedPinEvidence,c=>delete c.sharedLinkURL]){const c=sitePin();mutate(c);assert.throws(()=>places.validate(c));}});
test('coordinate-less location with pasted metadata still cannot invent a coordinate',()=>{assert.throws(()=>sitePin({lng:null},{sharedAddress:'대전 유성구 가상로 11'}));assert.throws(()=>redirectPin({address:null,pinId:'101'}));});
console.log(JSON.stringify({passed:checks.filter(c=>c.passed).length,total:checks.length,checks}));
if(checks.some(c=>!c.passed))process.exitCode=1;
