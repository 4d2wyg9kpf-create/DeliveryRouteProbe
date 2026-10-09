async (readerSource, profileSource) => {
  const read=(0,eval)('('+readerSource+')'),profile=(0,eval)('('+profileSource+')');
  const shown=e=>!!e&&e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden'&&getComputedStyle(e).display!=='none';
  const text=e=>String(e?.innerText||e?.textContent||'').replace(/\s+/g,' ').trim();
  const dialogs=()=>[...document.querySelectorAll('dialog,[role="dialog"]')].filter(shown);
  const stable=c=>JSON.stringify([c.mode,c.routePoints,c.vehicleClass,c.candidates,c.detail,c.departureTimeLabel]);
  const before=JSON.parse(read());
  if(!before.quality.readyForSummaryImport||!before.detail.matchesSelected||dialogs().length)return JSON.stringify(before);
  const button=[...document.querySelectorAll('[role="tabpanel"] button')].filter(shown).find(e=>/차량 기준$/.test(text(e)));
  if(!button)return JSON.stringify(before);
  const until=async fn=>{for(let i=0;i<16;i++){const v=fn();if(v)return v;await new Promise(resolve=>setTimeout(resolve,125));}return null;};
  let opened=null,observed=null;
  try{
    // Ordinary visible UI actions. Opening then closing does not save changes.
    button.click();
    opened=await until(()=>dialogs().find(d=>text(d).includes('차종/연료 설정')));
    if(!opened)throw Error('차량 설정창을 확인하지 못했습니다.');
    observed=profile();
  }finally{
    if(opened){const close=opened.querySelector('button.btn_close');if(close)close.click();}
  }
  if(!await until(()=>dialogs().length===0))throw Error('차량 설정창을 닫은 뒤 다시 읽어 주세요.');
  const after=JSON.parse(read());
  if(!after.quality.readyForSummaryImport||stable(before)!==stable(after))throw Error('차량 설정을 확인하는 동안 경로가 바뀌었습니다. 다시 읽어 주세요.');
  if(observed&&observed.vehicleClass===after.vehicleClass)after.observedVehicleSettings={...observed,confirmed:true};
  return JSON.stringify(after);
}
