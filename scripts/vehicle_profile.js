() => {
  // Only rendered controls in the vehicle dialog; no internal state or network.
  const tidy=x=>String(x||'').replace(/\s+/g,' ').trim();
  const shown=e=>!!e&&e.getClientRects().length>0&&getComputedStyle(e).visibility!=='hidden'&&getComputedStyle(e).display!=='none';
  const dialogs=[...document.querySelectorAll('dialog,[role="dialog"]')].filter(shown);
  const d=dialogs.find(e=>tidy(e.innerText||e.textContent).includes('차종/연료 설정'));
  if(!d||dialogs.length!==1)return null;
  const choices=[...d.querySelectorAll('input[name="checkbox_car"]')].filter(e=>e.checked);
  if(choices.length!==1)return null;
  const vehicleClass=tidy(choices[0].parentElement.innerText||choices[0].parentElement.textContent).match(/^[1-5]종(?:\(경차\))?/)?.[0]||null;
  const input=[...d.querySelectorAll('input[type="text"]')].find(e=>tidy(e.closest('label')?.textContent).startsWith('높이 제한'));
  let heightMM=null;
  if(input){
    const group=input.closest('li')?.parentElement;
    const presets=group?[...group.querySelectorAll('button.option_button.on')].filter(shown):[];
    const custom=tidy(input.value);
    if(presets.length===1&&!custom){
      const m=tidy(presets[0].innerText||presets[0].textContent).match(/^(\d+(?:\.\d+)?)m$/);
      if(m)heightMM=Math.round(Number(m[1])*1000);
    }else if(!presets.length&&/^\d+(?:\.\d+)?$/.test(custom))heightMM=Math.round(Number(custom)*1000);
  }
  return {vehicleClass,heightMM,source:'saved_dialog_reopen'};
}
