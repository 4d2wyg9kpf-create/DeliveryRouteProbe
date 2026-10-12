const assert=require('node:assert/strict');
const route=require('../scripts/facility_route_web.js');
let count=0;
function test(name,body){body();count++;console.log('PASS '+name);}
test('time units are summed, not concatenated',()=>assert.equal(route.duration('1시간 23분 45초'),5025));
test('days and minutes keep their units',()=>assert.equal(route.duration('1일 2시간 3분'),93780));
test('a missing predicted time is not zero',()=>assert.equal(route.duration('-분'),null));
test('duplicated total and leg minutes cannot be one duration',()=>assert.equal(route.duration('20분 8분 12분'),null));
test('kilometers convert to meters without losing decimals',()=>assert.equal(route.distance('1.7km'),1700));
test('meter grouping separators are understood',()=>assert.equal(route.distance('1,230m'),1230));
test('steps fares and calories never become distance',()=>{for(const s of ['2,680 걸음','1,550원','87kcal','250m 축척'])assert.equal(route.distance(s),null)});
const req={origin:{name:'출발 / #',longitude:126.9707,latitude:37.5548},destination:{name:'도착 &',longitude:126.9779,latitude:37.5663},mode:'walk'};
function mobile(r){const u=new URL('https://m.search.naver.com/search.naver');u.searchParams.set('nso_path',`placeType^place;name^${r.origin.name};longitude^${r.origin.longitude};latitude^${r.origin.latitude}|type^place;name^${r.destination.name};longitude^${r.destination.longitude};latitude^${r.destination.latitude}|objtype^path;by^walking`);return u;}
test('mobile coordinate redirect preserves endpoint names and order',()=>assert(route.mobileNaverIdentity(mobile(req),req)));
test('a changed endpoint cannot reuse previous result',()=>{const wrong=structuredClone(req);wrong.destination.longitude+=.001;assert(!route.mobileNaverIdentity(mobile(req),wrong))});
test('a different transport cannot reuse walking results',()=>assert(!route.mobileNaverIdentity(mobile(req),{...req,mode:'transit'})));
test('endpoint reversal is rejected',()=>assert(!route.mobileNaverIdentity(mobile(req),{...req,origin:req.destination,destination:req.origin})));
function projected(p){return[p.longitude*Math.PI/180*6378137,Math.log(Math.tan(Math.PI/4+p.latitude*Math.PI/360))*6378137,encodeURIComponent(p.name),'','SIMPLE_POI'].join(',')}
const pc=new URL(`https://map.naver.com/p/directions/${projected(req.origin)}/${projected(req.destination)}/-/car`);
test('desktop WGS84 route projection is checked independently of pixels',()=>assert(route.naverDesktopIdentity(pc,req)));
test('desktop route may not drift to another position',()=>assert(!route.naverDesktopIdentity(pc,{...req,origin:{...req.origin,latitude:req.origin.latitude+.0001}})));
console.log(`FACILITY_ROUTE_JS_CHECKS ${count}/${count}`);
