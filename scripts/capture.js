() => {
  // Read only the rendered map UI. No requests, private app state, or DOM writes.
  const tidy = value => String(value || "").replace(/\s+/g, " ").trim();
  const shown = element => {
    if (!element || !element.getClientRects().length) return false;
    const style = getComputedStyle(element);
    return style.display !== "none" && style.visibility !== "hidden";
  };
  const text = element => element ? tidy(element.innerText || element.textContent) : "";
  const all = (root, selector) => Array.from(root.querySelectorAll(selector));
  const distance = raw => {
    const match = tidy(raw).match(/^([\d,]+(?:\.\d+)?)\s*(km|m)$/i);
    return match ? Math.round(Number(match[1].replace(/,/g, "")) * (match[2].toLowerCase() === "km" ? 1000 : 1)) : null;
  };
  const minutes = raw => {
    const value = tidy(raw);
    if (!value || !/^(?:\d+\s*일\s*)?(?:\d+\s*시간\s*)?(?:\d+\s*분\s*)?(?:\d+\s*초\s*)?$/.test(value)) return null;
    const days = Number(value.match(/(\d+)\s*일/)?.[1] || 0);
    const hours = Number(value.match(/(\d+)\s*시간/)?.[1] || 0);
    const mins = Number(value.match(/(\d+)\s*분/)?.[1] || 0);
    const seconds = Number(value.match(/(\d+)\s*초/)?.[1] || 0);
    return days * 1440 + hours * 60 + mins + seconds / 60;
  };
  const money = raw => {
    if (/^통행료\s*무료$/.test(tidy(raw))) return 0;
    const match = tidy(raw).match(/^통행료\s*([\d,]+)\s*원$/);
    return match ? Number(match[1].replace(/,/g, "")) : null;
  };
  const panel = all(document, '[role="tabpanel"]').find(shown);
  const mode = text(all(document, '[role="tab"][aria-selected="true"]').find(el => /^(자동차|자전거|도보|대중교통)$/.test(text(el))));
  const inputPoints = all(document, 'input[role="combobox"]').filter(shown).map(input => ({
    label: tidy(Array.from(input.labels || []).map(label => text(label)).join(" ")),
    value: input.value || ""
  }));
  const summaryPoints = panel ? all(panel, '.direction_list .direction_text').map(text) : [];
  const cards = panel ? all(panel, '[role="button"][aria-pressed]').filter(el => shown(el) && el.querySelector('.route_summary_box')) : [];
  const candidates = cards.map(card => {
    const durationText = text(card.querySelector('.route_summary_info_duration strong'));
    const distanceText = text(card.querySelector('.route_summary_info_duration .item_distance'));
    const tollText = all(card, '.route_summary_info_list li').map(text).find(t => /^통행료/.test(t)) || "";
    const sections = all(card, 'ol li').map(row => {
      const congestion = text(row.querySelector('.item_icon'));
      const distanceText = text(row.querySelector('.item_distance'));
      // The road name is the row's rendered direct text, excluding the two spans.
      const road = tidy(Array.from(row.childNodes).filter(node => node.nodeType === 3).map(node => node.textContent).join(" "));
      return { road, congestion, distanceText, distanceMeters: distance(distanceText) };
    });
    return {
      index: Number(text(card.querySelector('.summary_label_badge'))) || null,
      label: text(card.querySelector('.summary_label_text')),
      selected: card.getAttribute('aria-pressed') === 'true',
      durationText, durationMinutes: minutes(durationText),
      distanceText, distanceMeters: distance(distanceText),
      tollText, tollWon: money(tollText), sections
    };
  });
  const selectedCandidates = candidates.filter(candidate => candidate.selected);
  const selected = selectedCandidates.length === 1 ? selectedCandidates[0] : null;
  const detailPanel = document.getElementById('sub_panel');
  const detailVisible = shown(detailPanel);
  const detailIndex = detailVisible ? Number(text(detailPanel.querySelector('.summary_label_badge'))) || null : null;
  const detailLabel = detailVisible ? text(detailPanel.querySelector('.summary_label_text')) : "";
  const detailDuration = detailVisible ? text(detailPanel.querySelector('.route_summary_info_duration strong')) : "";
  const detailDistance = detailVisible ? text(detailPanel.querySelector('.route_summary_info_duration .item_distance')) : "";
  const detailMatchesSelected = Boolean(selected && detailVisible && selected.index === detailIndex && selected.label === detailLabel && selected.durationText === detailDuration && selected.distanceText === detailDistance);
  const guides = detailMatchesSelected ? all(detailPanel, '.directions_detail_list > li').map(row => {
    const instruction = text(row.querySelector('.guide_info_route'));
    const icon = row.querySelector('.guide_info_icon img, .guide_item_icon img');
    const distanceText = text(row.querySelector('.guide_info_icon'));
    return { type: icon?.getAttribute('alt') || "", instruction, distanceText, distanceMeters: distance(distanceText) };
  }) : [];
  const arrivalSideText = detailMatchesSelected ? text(detailPanel.querySelector('.destination_panorama_text')) : "";
  const arrivalSide = /오른쪽/.test(arrivalSideText) ? 'right' : /왼쪽/.test(arrivalSideText) ? 'left' : /전방|앞쪽/.test(arrivalSideText) ? 'ahead' : null;
  const vehicleSummary = panel ? all(panel, 'button').map(text).find(t => /차량 기준$/.test(t)) || "" : "";
  const vehicleClass = vehicleSummary.match(/^(\d)종(?:\(경차\))?/)?.[0] || null;
  const dialogs = all(document, 'dialog, [role="dialog"]').filter(shown);
  const settings = dialogs.find(el => text(el).includes('차종/연료 설정'));
  const forecast = dialogs.find(el => text(el).includes('나중에 출발'));
  const settingsDraft = settings ? {
    note: "설정창의 현재 선택이며 저장·경로 반영을 확인한 값이 아닙니다.",
    checkedLabels: all(settings, 'input[type="checkbox"]').filter(el => el.checked).map(el => text(el.parentElement)),
    selectedPresets: all(settings, 'button.option_button.on').map(text),
    customValues: all(settings, 'input[type="text"]').filter(el => el.value).map(el => ({
      context: text(el.parentElement?.parentElement), value: el.value
    }))
  } : null;
  // With intermediate points the main summary lists only the two endpoints.
  // Bind all points to the selected detail's visible departure/via/arrival rows.
  const detailPoints = guides.filter(g => /^(출발지|도착지|경유지\d+)$/.test(g.type)).map(g => tidy(g.instruction));
  const routePoints = inputPoints.length > 2 ? detailPoints : summaryPoints;
  const summaryMatches = summaryPoints.length === 2 && routePoints.length >= 2 && summaryPoints[0] === routePoints[0] && summaryPoints[1] === routePoints[routePoints.length-1];
  const inputNames = inputPoints.map(point => tidy(point.value)).filter(Boolean);
  const inputMatchesRoute = summaryMatches && routePoints.length >= 2 && inputNames.length === routePoints.length && inputNames.every((name, i) => name === tidy(routePoints[i]));
  const searchOpen = all(document, '[role="listbox"]').some(shown);
  const issues = [];
  if (mode !== '자동차') issues.push('자동차 길찾기 화면에서 읽어 주세요.');
  if (!candidates.length) issues.push('자동차 경로 결과가 아직 없거나 화면 구조가 달라졌습니다.');
  if (candidates.length && !selected) issues.push('선택된 경로를 하나로 확인할 수 없습니다.');
  if (candidates.length && !inputMatchesRoute) issues.push('입력 중인 장소와 계산된 경로의 장소가 일치하지 않습니다.');
  if (searchOpen) issues.push('장소 검색·선택을 마친 뒤 다시 읽어 주세요.');
  if (settings) issues.push('차량 설정창의 선택은 아직 경로에 반영되지 않았을 수 있습니다.');
  if (dialogs.length && !settings) issues.push('열린 안내창을 닫은 뒤 경로를 다시 읽어 주세요.');
  if (detailVisible && !detailMatchesSelected) issues.push('상세 안내가 선택된 경로와 일치하지 않습니다.');
  if (selected && (selected.durationMinutes === null || selected.distanceMeters === null)) issues.push('선택된 경로의 시간 또는 거리를 해석하지 못했습니다.');
  const readyForSummaryImport = mode === '자동차' && Boolean(selected) && inputMatchesRoute && !searchOpen && !dialogs.length && selected.durationMinutes !== null && selected.distanceMeters !== null;
  return JSON.stringify({
    schemaVersion: 1, extractorVersion: '0.5.0', mode, inputPoints, routePoints,
    vehicleSummary, vehicleClass, settingsDraft,
    departureForecastText: forecast ? text(forecast) : null,
    departureTimeLabel: panel ? text(panel.querySelector('.later_departure_btn_text')) : "",
    sourceTimeText: text(all(document, '.time_info_text').find(shown)),
    candidates, detail: { visible: detailVisible, routeIndex: detailIndex, matchesSelected: detailMatchesSelected, guides, arrivalSide, arrivalSideText },
    quality: {
      inputMatchesRoute, readyForSummaryImport,
      departureDirectionVerified: false, arrivalCurbVerified: false,
      heightClearanceVerified: false, class1FareForHeightRouteVerified: false,
      fullRoadGeometryAvailable: false, routeLockVerified: false,
      trafficFreshnessVerified: false,
      issues
    }
  });
}
