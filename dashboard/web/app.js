'use strict';
// cct 대시보드 프론트 - /api/state 를 폴링해 렌더하고, 버튼은 실제 엔드포인트를 호출한다.
// 표시 로직(추천 계정·중복 판정·게이지)은 클라이언트, 사실은 서버가 내려준다.
// 2026-09-16 Beszel 계열 UI 리팩터링: API·뷰모델·액션 계약은 그대로, 렌더만 교체했다.
(function(){
var M = 60e3, H = 3600e3, D = 86400e3;
var RESERVED = ['help','ls','list','add','run','rm','rename','status','doctor','check','fp','who','usage','off','active','refresh','use'];
var WARN_AT = 65, CRIT_AT = 90;   // 사용률 임계 기본값 - 서버 settings 가 단일 출처(색·배지·알림 공용)
var S = null;          // 뷰모델
var RAW = null;        // 마지막 /api/state 원본
var HIST = null;       // /api/history 시리즈 {라벨: [[at,u5,u7,uf],...]}
var HIST_HOURS = 24;   // 스파크라인 범위(시간)
var TOK = null;        // 마지막 /api/tokens 응답
var TOK_DAYS = 30;     // 토큰 집계 기간(일)
var tokTimer = null;   // 스캔 중 3초 폴링 타이머
var busy = false;

function el(id){ return document.getElementById(id); }
function esc(s){ return String(s).replace(/[&<>"]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
function pad(n){ return (n<10?'0':'')+n; }
function ms(sec){ return (sec===null||sec===undefined) ? null : sec*1000; }
function clock(ts, withDate){ var d=new Date(ts); var t=pad(d.getHours())+':'+pad(d.getMinutes()); return withDate ? pad(d.getMonth()+1)+'-'+pad(d.getDate())+' '+t : t; }
function remaining(ts){ var diff=ts-Date.now(); if(diff<=0) return '지남'; var d=Math.floor(diff/D), h=Math.floor(diff%D/H), m=Math.floor(diff%H/M); if(d>0) return d+'d'+h+'h'; if(h>0) return h+'h'+m+'m'; return m+'m'; }
function resetText(ts, withDate){ if(!ts) return '리셋 -'; return remaining(ts)+' · '+clock(ts, withDate); }
function ago(ts){ if(!ts) return '-'; var s=Math.round((Date.now()-ts)/1000); if(s<60) return s+'초 전'; if(s<3600) return Math.round(s/60)+'분 전'; return Math.round(s/3600)+'시간 전'; }
function pct(u){ return (u===null||u===undefined) ? '-' : Math.round(u*100)+'%'; }
function fmtDur(ms){ if(ms<M) return '방금'; var d=Math.floor(ms/D), h=Math.floor(ms%D/H), m=Math.floor(ms%H/M); if(d>0) return d+'d'+h+'h'; if(h>0) return h+'h'+m+'m'; return m+'m'; }
function fmtTok(n){ n=n||0; if(n>=1e9) return (n>=1e10?Math.round(n/1e9):(n/1e9).toFixed(1))+'B'; if(n>=1e6) return (n>=1e7?Math.round(n/1e6):(n/1e6).toFixed(1))+'M'; if(n>=1e3) return (n>=1e4?Math.round(n/1e3):(n/1e3).toFixed(1))+'K'; return String(Math.round(n)); }
function usd(v){ v=v||0; return '$'+(v>=100 ? v.toFixed(0) : v.toFixed(2)); }
function dstr(ts){ var d=new Date(ts); return d.getFullYear()+'-'+pad(d.getMonth()+1)+'-'+pad(d.getDate()); }
function acc(l){ if(!S) return null; return S.accounts.filter(function(x){ return x.label===l; })[0]; }
function fpKey(a){ return (a.org && a.w7 && a.w7.r) ? a.org+'|'+a.w7.r : null; }
function dupMap(){ var m={}; S.accounts.forEach(function(a){ var k=fpKey(a); if(k){ (m[k]=m[k]||[]).push(a.label); } }); return m; }
function validLabel(l){ if(!l) return '라벨이 비어 있음'; if(!/^[a-z0-9_]+$/.test(l)) return '라벨은 소문자 영문/숫자/_ 만 허용'; if(RESERVED.indexOf(l)>=0) return l+' 는 예약어(서브커맨드)'; return ''; }
function writeOn(){ return el('chk-write').checked; }

// ── API ───────────────────────────────────────────────────────────
function api(path, body){
  var opt = { method: body===undefined ? 'GET' : 'POST', headers: {} };
  if(body!==undefined){ opt.headers['Content-Type']='application/json'; opt.body=JSON.stringify(body); }
  if(writeOn()) opt.headers['X-CCT-Write']='1';
  return fetch(path, opt).then(function(r){
    return r.json().catch(function(){ return {error:{code:'bad_json',message:'응답을 해석할 수 없음 (HTTP '+r.status+')'}}; })
      .then(function(j){ if(!r.ok || (j && j.error)) throw new Error((j && j.error && j.error.message) || ('HTTP '+r.status)); return j; });
  });
}

// ── /api/state → 뷰모델 ───────────────────────────────────────────
function win(w){ return w ? {u:w.utilization, r:ms(w.reset), s:w.status} : null; }
// cct status 는 활성 라벨이 없을 때 none/invalid 를 그대로 출력한다. 서버와 같은 규칙으로 정규화한다.
function label0(v){ return (v===null||v===undefined||v===''||v==='none'||v==='invalid'||v==='-') ? '' : v; }
function toView(st){
  var v = {
    server: st.server || {},
    status: {
      wallet: (st.status&&st.status.wallet)||'-', mode:(st.status&&st.status.mode)||'-',
      accounts:(st.status&&st.status.accounts)||0, active:label0(st.status&&st.status.active),
      def:label0(st.status&&st.status['default']), sticky:(st.status&&st.status.sticky)||'-',
      claude:(st.status&&st.status.claude_version)||'-'
    },
    budget: st.budget || {},
    refreshing: !!st.refreshing,
    settings: st.settings || {},
    alerts: st.alerts ? {active: st.alerts.active || [], events: st.alerts.events || []}
                      : {active: [], events: []},
    live: null,
    doctor: (st.doctor && st.doctor.items) || [],
    log: (st.log||[]).map(function(x){ return {at:ms(x.at), cmd:x.cmd, rc:x.rc, ms:x.ms}; }),
    accounts: (st.accounts||[]).map(function(a){
      var u = a.usage || null, w = (u && u.windows) || {};
      return {
        label: a.label, token: !!a.has_token, isActive: !!a.active, isDefault: !!a['default'],
        ok: !!(u && u.state === 'ok'),
        state: u ? u.state : null,
        probeAt: ms(a.usage_at), org: u ? u.org : null,
        denied: (u && u.probe) ? u.probe.denied : null,
        w5: win(w['5h']), w7: win(w['7d']), wf: win(w['7d_oi']),
        check: a.check ? {res:a.check.result, at:ms(a.check.at)} : null
      };
    })
  };
  if(st.live){
    v.live = {
      at: ms(st.live.at), stale: !!st.live.stale, label: st.live.label_guess || v.status.active,
      model: st.live.model || '-', ctx: st.live.context_pct, cost: st.live.cost_usd,
      fiveH: st.live.five_hour || null, sevenD: st.live.seven_day || null
    };
  }
  // 임계값은 서버 설정이 단일 출처 - 미터 색·카드 배지·알림 스트립이 같은 값을 쓴다.
  if(typeof v.settings.alert_warn === 'number') WARN_AT = v.settings.alert_warn;
  if(typeof v.settings.alert_crit === 'number') CRIT_AT = v.settings.alert_crit;
  return v;
}

// 병목 창 기준 점수: 정의된 모든 창(5h/7d/7f) 중 가장 높은 사용률.
// 5h 만 보면 7d 가 97% 인 계정을 추천하는 오판이 나온다(실측).
function headroom(a){
  var u = -1;
  [a.w5, a.w7, a.wf].forEach(function(w){
    if(w && w.u!==null && w.u!==undefined && w.u>u) u = w.u;
  });
  return u;
}
function recommend(){
  var active = acc(S.status.active), ak = active ? fpKey(active) : null;
  var c = S.accounts.filter(function(a){
    if(!a.token || !a.ok || !a.w5 || !a.w7) return false;
    if(a.w5.u===null || a.w7.u===null) return false;
    // 어느 창이든 rejected 면 제외
    if([a.w5,a.w7,a.wf].some(function(w){ return w && w.s==='rejected'; })) return false;
    return true;
  });
  c = c.filter(function(a){ return !(ak && fpKey(a)===ak && a.label!==S.status.active); });
  c.sort(function(x,y){ return (headroom(x)-headroom(y)) || (x.w5.u-y.w5.u); });
  return c[0] || null;
}

// ── 렌더 조각 ─────────────────────────────────────────────────────
// 사용률 임계값 3색: 65 미만 여유, 65~89 주의, 90 이상 위험.
function fillClass(p, w){ if(w && w.s==='rejected') return 'c'; if(p>=CRIT_AT) return 'c'; if(p>=WARN_AT) return 'w'; return ''; }
function statusNote(s){ return (s && s!=='allowed') ? s.replace('allowed_','') : ''; }

// 미터 한 줄: [창][사용률][바][리셋까지 남은 시간 · 정확한 리셋 시각].
// 모든 카드가 같은 좌표에 같은 정보를 놓는다. 창 상태(allowed_warning/rejected)는
// 리셋 시각을 덮어쓰지 않고 창 이름·사용률의 색과 카드 배지, 툴팁으로 알린다.
function metric(key, w, withDate){
  if(!w || w.u===null || w.u===undefined){
    return naMetric(key, w ? '확인 불가' : '미지원', false);
  }
  var p = Math.min(100, Math.max(0, Math.round(w.u*100)));
  var note = statusNote(w.s);
  var sev = w.s==='rejected' ? ' bad' : (note ? ' warn' : '');
  var right = w.r ? resetText(w.r, withDate) : '리셋 -';
  var title = key + ' ' + p + '%' + (note ? ' · 창 상태 ' + w.s : '')
    + ' · ' + (w.r ? '리셋 ' + clock(w.r, true) : '리셋 정보 없음');
  return '<div class="m" title="'+esc(title)+'"><span class="mk'+sev+'">'+key+'</span><span class="mv'+sev+'">'+p+'%</span>'
       + '<span class="track"><i class="'+fillClass(p,w)+'" style="width:'+p+'%"></i></span>'
       + '<span class="mr">'+esc(right)+'</span></div>';
}
// 데이터가 없는 창은 가짜 숫자 대신 사유를 적는다.
function naMetric(key, why, flag){
  return '<div class="m"><span class="mk">'+key+'</span><span class="mv na">-</span>'
       + '<span class="track na"></span><span class="mr'+(flag?' flag':'')+'">'+esc(why)+'</span></div>';
}

// ── 스파크라인 - /api/history 시리즈를 카드 폭 SVG 로 그린다 ─────────
// 텍스트 노드 없이 숫자 좌표만 쓴다(esc 규율). null 구간은 선을 끊는다.
function sparkPath(pts, idx, x0, span){
  var d = '', pen = false;
  for(var i=0;i<pts.length;i++){
    var u = pts[i][idx];
    if(u===null || u===undefined){ pen = false; continue; }
    var x = (pts[i][0]-x0)/span*240, y = 2+(1-Math.max(0,Math.min(1,u)))*30;
    d += (pen?'L':'M')+x.toFixed(1)+' '+y.toFixed(1)+' ';
    pen = true;
  }
  return d ? d.trim() : '';
}
function sparkline(label){
  var pts = HIST && HIST[label];
  if(!pts || !pts.length) return '';          // 히스토리 없는 카드는 영역 자체를 만들지 않는다
  var span = HIST_HOURS*3600, x0 = Date.now()/1000 - span;
  var d5 = sparkPath(pts, 1, x0, span), d7 = sparkPath(pts, 2, x0, span);
  if(!d5 && !d7) return '';
  var yw = (2+(1-WARN_AT/100)*30).toFixed(1), yc = (2+(1-CRIT_AT/100)*30).toFixed(1);
  var rng = HIST_HOURS>=168 ? '7d' : HIST_HOURS+'h';
  return '<div class="spark" title="'+esc('최근 '+rng+' 사용률 - 주황 7d · 회색 5h · 가로선 임계 '+WARN_AT+'/'+CRIT_AT+'%')+'">'
    + '<svg viewBox="0 0 240 34" preserveAspectRatio="none" aria-hidden="true">'
    + '<line class="gc" x1="0" y1="'+yc+'" x2="240" y2="'+yc+'"/>'
    + '<line class="gw" x1="0" y1="'+yw+'" x2="240" y2="'+yw+'"/>'
    + (d5 ? '<path class="sp5" d="'+d5+'"/>' : '')
    + (d7 ? '<path class="sp7" d="'+d7+'"/>' : '')
    + '</svg></div>';
}

// ── 렌더 ──────────────────────────────────────────────────────────
function renderTop(){
  var sv = S.server||{}, b = S.budget||{};
  el('conn').innerHTML = '<i class="dot '+(sv.fake?'fake':'live')+'"></i><span>'+(sv.fake?'픽스처 모드':'실계정 연결')
    + '</span><span class="bind">'+esc(sv.bind||'-')+(sv.version?' v'+esc(sv.version):'')+'</span>';
  var probed = S.accounts.filter(function(a){ return a.probeAt; }).map(function(a){ return a.probeAt; });
  var last = probed.length ? Math.max.apply(null, probed) : null;
  var n = S.accounts.filter(function(a){ return a.token; }).length;
  var perDay = b.auto_min ? Math.round(n * (24*60/b.auto_min)) : 0;
  el('tmeta').innerHTML =
      '<span class="item">마지막 갱신 <b>'+(last ? ago(last)+' '+clock(last,false) : '없음')+'</b></span>'
    + '<span class="item'+((b.usage_probes||0)+(b.check_probes||0) ? ' hot' : '')+'" title="usage 프로브는 실제 요청이라 사용량을 소비합니다">'
    + '오늘 프로브 <b>'+((b.usage_probes||0)+(b.check_probes||0))+'회 · '+(b.est_tokens||0)+' tok</b></span>'
    + '<span class="item">'+(b.auto_min ? '자동 '+b.auto_min+'분'+(perDay ? ' <b>하루 '+perDay+'회</b>' : ' <b>대상 없음</b>') : '자동 갱신 <b>끔</b>')+'</span>';
  var sel = el('sel-auto'); if(String(b.auto_min) !== sel.value) sel.value = String(b.auto_min===undefined?0:b.auto_min);
  var rb = el('btn-refresh');
  rb.disabled = !!S.refreshing;
  rb.innerHTML = S.refreshing ? '<span class="spin"></span> 갱신 중' : '전체 갱신';
  el('cards-hint').innerHTML = '<code>cct usage --all</code> · 사용률 '+WARN_AT+'% 이상 주의, '+CRIT_AT+'% 이상 위험';
}

function liveBits(){
  var L = S.live;
  if(!L) return '<span class="lk">statusline 캐시 없음 <b>-</b></span>';
  var five = L.fiveH||{}, seven = L.sevenD||{};
  var out = [];
  out.push('<span class="lk">5h <b>'+(five.used_percentage===undefined?'-':five.used_percentage+'%')+'</b>'
    + (five.resets_at?' <span>'+remaining(ms(five.resets_at))+'</span>':'')+'</span>');
  out.push('<span class="lk">7d <b>'+(seven.used_percentage===undefined?'-':seven.used_percentage+'%')+'</b>'
    + (seven.resets_at?' <span>'+remaining(ms(seven.resets_at))+'</span>':'')+'</span>');
  out.push('<span class="lk">모델 <b>'+esc(L.model)+'</b></span>');
  out.push('<span class="lk">컨텍스트 <b>'+(L.ctx===null||L.ctx===undefined?'-':L.ctx+'%')+'</b></span>');
  out.push('<span class="lk">세션 <b>$'+(L.cost||0).toFixed(2)+'</b></span>');
  out.push('<span class="lk'+(L.stale?' stale':'')+'" title="Claude Code statusline 캐시 · 프로브 0회">'
    + (L.stale?'stale ':'')+'<b>'+ago(L.at)+'</b></span>');
  return out.join('');
}
function renderActiveBar(){
  var bar = el('activebar'), st = S.status, a = acc(st.active), r = recommend();
  var badges = '';
  if(a){
    if(a.isDefault) badges += '<span class="badge">기본</span>';
    badges += '<span class="badge">sticky '+esc(st.sticky)+'</span>';
  }
  var head = st.active
    ? '<span class="ab-eyebrow">활성 계정</span><span class="ab-label">'+esc(st.active)+'</span>'+badges
    : '<span class="ab-eyebrow">활성 계정</span><span class="ab-label">없음</span>'
      + '<span class="badge">기본 '+esc(st.def||'-')+' 로 실행</span>';
  var act = '', note = '';
  if(!r){
    note = '갈아탈 후보 없음 · 프로브된 계정이 없거나 모두 소진·무효입니다';
  } else if(r.label === st.active){
    note = '현재 계정이 가장 여유롭습니다 · 병목 <b>'+pct(headroom(r))+'</b>';
  } else {
    note = '추천 <b>'+esc(r.label)+'</b> · 병목 '+pct(headroom(r))+' · 5h '+pct(r.w5.u)+' / 7d '+pct(r.w7.u);
    act = '<button class="btn ghost sm" data-act="copy" data-l="'+esc(r.label)+'" title="cct '+esc(r.label)+'">복사</button>'
        + '<button class="btn accent" data-act="use" data-l="'+esc(r.label)+'">'+esc(r.label)+' 로 전환</button>';
  }
  bar.className = 'activebar' + (st.active ? '' : ' none');
  bar.innerHTML = '<div class="ab-main">'+head+'</div>'
    + '<div class="ab-live">'+liveBits()+'</div>'
    + '<div class="ab-act"><span class="ab-rec">'+note+'</span>'+act+'</div>';
}

function checkBit(a){
  if(!a.check) return '<span class="mi">check <b>미확인</b></span>';
  var t = a.check.res==='valid' ? ['ok','유효'] : a.check.res==='invalid' ? ['bad','무효'] : ['warn','토큰 없음'];
  return '<span class="mi">check <b class="'+t[0]+'">'+t[1]+'</b>'+(a.check.at?' <span>'+ago(a.check.at)+'</span>':'')+'</span>';
}
function cardMenu(a){
  var dis = a.token ? '' : ' disabled';
  return '<details class="menu"><summary class="btn sm icon" title="더보기" aria-label="더보기" role="button">&#8943;</summary>'
    + '<div class="pop">'
    + '<button class="mi" type="button" data-act="check" data-l="'+esc(a.label)+'"'+dis+'>토큰 점검 <span class="mono">cct check</span></button>'
    + '<button class="mi" type="button" data-act="copy" data-l="'+esc(a.label)+'">명령 복사 <span class="mono">cct '+esc(a.label)+'</span></button>'
    + '<div class="sep write-only"></div>'
    + '<button class="mi write-only" type="button" data-act="rename" data-l="'+esc(a.label)+'">이름 변경</button>'
    + '<button class="mi danger write-only" type="button" data-act="rm" data-l="'+esc(a.label)+'">계정 삭제</button>'
    + '</div></details>';
}
function accountCard(a, dups, rec){
  var isRec = rec && rec.label===a.label && !a.isActive;
  var bad = a.token && (a.state==='no_response' || a.state==='parse_error' || (a.check && a.check.res==='invalid'));
  var top = headroom(a);
  var cls = 'acct' + (a.isActive?' is-active':'') + ((!a.token||!a.ok)?' is-dim':'');
  var badges = '';
  if(a.isActive) badges += '<span class="badge acc"><i class="dot on"></i>활성</span>';
  if(a.isDefault) badges += '<span class="badge">기본</span>';
  if(isRec) badges += '<span class="badge ok">추천</span>';
  var rej = [['5h',a.w5],['7d',a.w7],['7f',a.wf]].filter(function(p){ return p[1] && p[1].s==='rejected'; })
                                                 .map(function(p){ return p[0]; });
  if(!a.token) badges += '<span class="badge">미등록</span>';
  else if(a.state==='no_response') badges += '<span class="badge bad">무효</span>';
  else if(a.state==='parse_error') badges += '<span class="badge bad">해석 실패</span>';
  else if(!a.probeAt || !a.w5) badges += '<span class="badge">미확인</span>';
  else if(rej.length) badges += '<span class="badge bad">'+rej.join('/')+' 차단</span>';
  else if(top>=CRIT_AT/100) badges += '<span class="badge bad">'+pct(top)+' 소진</span>';
  else if(top>=WARN_AT/100) badges += '<span class="badge warn">'+pct(top)+' 사용</span>';
  var k = fpKey(a);
  if(k && dups[k].length>1){
    var others = dups[k].filter(function(l){ return l!==a.label; });
    badges += '<span class="badge warn" title="org·7d_reset 이 같으면 같은 계정입니다">중복 '+esc(others.join(','))+'</span>';
  }

  var body, note = '';
  if(!a.token){
    body = naMetric('5h','미등록') + naMetric('7d','미등록') + naMetric('7f','미등록');
    note = '<div class="ac-note">지갑에 토큰이 없습니다. 쓰기 모드에서 등록하거나 터미널에서 <code>cct add '+esc(a.label)+'</code></div>';
  } else if(a.state==='no_response'){
    body = naMetric('5h','응답 실패') + naMetric('7d','응답 실패') + naMetric('7f','응답 실패');
    note = '<div class="ac-note bad">프로브 응답 실패 - 토큰 무효·만료 가능성. 재발급 후 <code>cct add '+esc(a.label)+'</code> 로 교체하세요.</div>';
  } else if(a.state==='parse_error'){
    body = naMetric('5h','해석 실패') + naMetric('7d','해석 실패') + naMetric('7f','해석 실패');
    note = '<div class="ac-note bad">usage 출력 해석 실패 - 서버 로그를 확인하세요.</div>';
  } else if(!a.w5){
    body = naMetric('5h','미확인') + naMetric('7d','미확인') + naMetric('7f','미확인');
    note = '<div class="ac-note">아직 프로브하지 않았습니다. 갱신을 누르면 <code>cct usage</code> 를 실행합니다.</div>';
  } else {
    body = metric('5h', a.w5, false) + metric('7d', a.w7, true);
    body += a.denied ? naMetric('7f', '프로브 거부 '+a.denied, true) : metric('7f', a.wf, true);
  }

  var probeTxt = a.probeAt ? ago(a.probeAt) : (a.token ? '미확인' : '-');
  var meta = '<div class="ac-meta"><span class="mi">확인 <b>'+probeTxt+'</b></span>'
    + (a.org ? '<span class="mi">org <b>'+esc(a.org)+'</b></span>' : '<span class="mi">org <b>-</b></span>')
    + checkBit(a) + '</div>';
  var dis = a.token ? '' : ' disabled';
  var act = '<div class="ac-act">'
    + (a.isActive
        ? '<button class="btn sm" data-act="copy" data-l="'+esc(a.label)+'">cct '+esc(a.label)+' 복사</button>'
        : '<button class="btn sm link-accent" data-act="use" data-l="'+esc(a.label)+'"'+dis+'>이 계정으로 전환</button>')
    + '<button class="btn sm" data-act="usage" data-l="'+esc(a.label)+'"'+dis+' title="cct usage - 실프로브라 사용량을 소비합니다">갱신</button>'
    + '</div>';
  return '<article class="'+cls+'"><div class="ac-head"><span class="lbl" title="'+esc(a.label)+'">'+esc(a.label)+'</span>'
    + '<span class="ac-badges">'+badges+'</span>'+cardMenu(a)+'</div>'
    + '<div class="ac-metrics">'+body+'</div>'+sparkline(a.label)+note+meta+act+'</article>';
}
function addCard(){
  return '<article class="acct add"><div class="ac-head"><span class="lbl">새 계정</span>'
    + '<span class="ac-badges"><span class="badge">cct add</span></span></div>'
    + '<form id="form-add">'
    + '<input id="add-label" type="text" placeholder="라벨 (a-z0-9_)" autocomplete="off" required>'
    + '<input id="add-token" type="password" placeholder="setup-token (화면·로그 미표시)" autocomplete="off" required>'
    + '<label class="swlabel"><input type="checkbox" id="add-ow"><span class="note">기존 라벨 덮어쓰기</span></label>'
    + '<div class="row"><button class="btn link-accent" type="submit">등록</button>'
    + '<span class="note">토큰은 stdin 으로만 전달되고 지갑 mode 600 을 유지합니다.</span></div>'
    + '</form></article>';
}
function renderCards(){
  var host = el('cards');
  if(!S.accounts.length){
    host.innerHTML = '<div class="empty"><b>등록된 계정이 없습니다</b>'
      + '<span>터미널에서 <code>cct add &lt;라벨&gt;</code> 로 setup-token 을 등록하면 여기에 카드가 생깁니다.</span></div>' + addCard();
    return;
  }
  var dups = dupMap(), rec = recommend();
  host.innerHTML = S.accounts.map(function(a){ return accountCard(a, dups, rec); }).join('') + addCard();
}

function renderTimeline(){
  var winMs = 24*H, now = Date.now(), axis = '', rows = '', later = [];
  for(var i=0;i<=24;i+=6){ axis += '<span style="left:'+(i/24*100)+'%">'+(i===0?'지금':(i===24?'+24h':'+'+i+'h'))+'</span>'; }
  S.accounts.forEach(function(a){
    if(!a.token||!a.ok||!a.w5) return;
    var dots = '';
    [['5h',a.w5,'d5',false],['7d',a.w7,'d7',true],['7f',a.wf,'df',true]].forEach(function(p){
      var w=p[1]; if(!w||!w.r) return;
      var x=(w.r-now)/winMs;
      if(x>=0 && x<=1) dots += '<span class="tl-dot '+p[2]+'" style="left:'+(x*100)+'%" title="'+esc(a.label)+' '+p[0]+' 리셋 '+resetText(w.r,p[3])+'"></span>';
      else if(x>1 && p[0]==='7d') later.push(esc(a.label)+' '+resetText(w.r,true));
    });
    rows += '<div class="tl-row'+(a.isActive?' act':'')+'"><span class="who" title="'+esc(a.label)+'">'+esc(a.label)+'</span><div class="tl-track">'+dots+'</div></div>';
  });
  el('timeline').innerHTML = '<div class="tl-axis">'+axis+'</div>'
    + (rows || '<div class="hint" style="padding:12px 0 2px">프로브된 계정이 없습니다. 상단에서 전체 갱신을 실행하세요.</div>');
  el('tl-legend').innerHTML = '<span><i class="d5"></i>5h</span><span><i class="d7"></i>7d</span><span><i class="df"></i>7f</span>'
    + '<span>24h 밖 7d 리셋: '+(later.length ? later.join(' · ') : '없음')+'</span>';
}

function diagRow(x){
  var i = x.msg.indexOf(':');
  var nm = i>0 ? x.msg.slice(0,i) : x.lv.toLowerCase();
  var ds = i>0 ? x.msg.slice(i+1).trim() : x.msg;
  var ic = x.lv==='PASS' ? 'PASS' : x.lv==='WARN' ? 'WARN' : 'FAIL';
  return '<div class="diag-row '+x.lv+'"><span class="ic">'+ic+'</span><span class="nm">'+esc(nm)+'</span><span class="ds">'+esc(ds)+'</span></div>';
}
function renderDoctor(){
  var d = S.doctor, host = el('doctor');
  var passes = d.filter(function(x){ return x.lv==='PASS'; });
  var probs  = d.filter(function(x){ return x.lv!=='PASS'; });
  var nW = d.filter(function(x){ return x.lv==='WARN'; }).length;
  var nF = d.filter(function(x){ return x.lv==='FAIL'; }).length;
  el('diag-sum').innerHTML = d.length
    ? '<i class="dot '+(nF?'bad':nW?'warn':'ok')+'"></i> '+passes.length+' PASS · '+nW+' WARN · '+nF+' FAIL'
    : '결과 없음';
  if(!d.length){ host.innerHTML = '<div class="hint">cct doctor 결과가 없습니다.</div>'; return; }
  var open = el('fold-pass') && el('fold-pass').open;
  host.innerHTML = probs.map(diagRow).join('')
    + (passes.length
        ? '<details class="fold" id="fold-pass"'+(open?' open':'')+'><summary>정상 '+passes.length+'개 보기</summary>'
          + '<div class="fold-body">'+passes.map(diagRow).join('')+'</div></details>'
        : '');
  var st = S.status;
  el('wallet-meta').innerHTML = [
    ['wallet', st.wallet], ['mode', st.mode], ['accounts', String(st.accounts)],
    ['active', st.active||'없음'], ['default', st.def||'-'], ['sticky', st.sticky], ['claude', st.claude]
  ].map(function(p){ return '<span class="kv">'+p[0]+' <b>'+esc(p[1])+'</b></span>'; }).join('');
}

function renderLog(){
  var L = S.log;
  var sum = el('logblock').querySelector('summary .hint');
  if(sum) sum.textContent = L.length ? '최근 ' + Math.min(L.length,12) + '건 · 토큰 값은 기록하지 않음' : '기록 없음';
  el('log').innerHTML = L.length ? L.slice(0,12).map(function(x){
    var d=new Date(x.at);
    return '<li><span class="t">'+clock(x.at,false)+':'+pad(d.getSeconds())+'</span>'
      + '<span class="c">'+esc(x.cmd)+'</span>'
      + '<span class="rc'+(x.rc===0?'':' bad')+'">rc '+x.rc+'</span>'
      + '<span class="ms">'+x.ms+'ms</span></li>';
  }).join('') : '<li><span class="c">기록 없음</span></li>';
}

// ── 알림 스트립 - 임계 교차·프로브 실패를 카드보다 먼저 보여준다 ──────
function alertPill(x){
  var lv = x.level==='crit' ? 'bad' : 'warn';
  var txt, tip;
  if(x.win==='probe'){
    txt = esc(x.label)+' 프로브 실패';
    tip = x.label+' 프로브 실패 - 토큰 무효·만료 가능성';
  } else if(x.status==='rejected'){
    txt = esc(x.label)+' '+esc(x.win)+' 차단';
    tip = x.label+' '+x.win+' 창 차단(rejected) - 리셋까지 대기';
  } else {
    txt = esc(x.label)+' '+esc(x.win)+' '+pct(x.util);
    tip = x.label+' '+x.win+' '+pct(x.util)+' - '+(x.level==='crit'?'위험':'주의')+' 임계 초과';
  }
  var dur = x.since ? Date.now()-x.since*1000 : 0;
  return '<span class="apill '+lv+'" title="'+esc(tip)+'">'+txt+(dur>=M ? ' · '+fmtDur(dur) : '')+'</span>';
}
function alertEvRow(e){
  var t = e.level==='ok' ? ['ok','해소'] : e.level==='crit' ? ['bad','위험'] : ['warn','주의'];
  var what = esc(e.label||'-')+' '+(e.win==='probe' ? '프로브' : esc(e.win||'-'));
  var u = (e.util===null||e.util===undefined) ? '' : ' '+pct(e.util);
  return '<div class="aev"><span class="t">'+clock(ms(e.at),true)+'</span>'
    + '<span class="lv '+t[0]+'">'+t[1]+'</span><span class="w">'+what+u+'</span></div>';
}
function renderAlerts(){
  var host = el('alertstrip');
  var A = (S && S.alerts) || {active:[], events:[]};
  var act = A.active || [];
  if(!act.length){ host.hidden = true; host.innerHTML = ''; return; }
  host.hidden = false;
  if(host.querySelector('details[open]')) return;   // 기록을 보는 중엔 재빌드하지 않는다
  var nc = act.filter(function(x){ return x.level==='crit'; }).length;
  var ev = (A.events||[]).slice(0,10);
  host.className = 'alertstrip' + (nc ? ' crit' : '');
  host.innerHTML = '<span class="as-head '+(nc?'bad':'warn')+'">알림 '+act.length+'</span>'
    + '<div class="as-list">'+act.map(alertPill).join('')+'</div>'
    + '<details class="menu ahist"><summary class="btn sm" title="최근 알림 이벤트 10건">기록</summary><div class="pop">'
    + (ev.length ? ev.map(alertEvRow).join('') : '<p class="note">이벤트 없음</p>')
    + '</div></details>';
}

// ── 임계·알림 설정 - 서버 검증이 최종, 실패하면 입력값을 원복한다 ────
function syncSettings(){
  var st = (S && S.settings) || {};
  [['in-warn','alert_warn',WARN_AT], ['in-crit','alert_crit',CRIT_AT]].forEach(function(p){
    var i = el(p[0]);
    if(i && document.activeElement!==i) i.value = (typeof st[p[1]]==='number') ? st[p[1]] : p[2];
  });
  var sn = el('sel-notify');
  if(sn && document.activeElement!==sn) sn.value = st.notify || 'crit';
}
function pushThresholds(){
  if(!S) return;
  var st = S.settings || {};
  var w = parseInt(el('in-warn').value, 10), c = parseInt(el('in-crit').value, 10);
  if(w===st.alert_warn && c===st.alert_crit) return;
  if(!(w>=1 && w<c && c<=99)){ toast('임계는 1 <= 주의 < 위험 <= 99 여야 합니다', true); syncSettings(); return; }
  api('/api/settings', {alert_warn:w, alert_crit:c}).then(function(r){
    if(r.state){ RAW = r.state; S = toView(r.state); render(menuOpen()); }
    toast('임계 갱신: 주의 '+w+'% · 위험 '+c+'%');
  }).catch(function(e){ toast('임계 변경 실패: '+e.message, true); syncSettings(); });
}

// ── 토큰·비용 패널 - ~/.claude/projects JSONL 로컬 집계(프로브 0회) ──
function tokChip(name, o){
  var tk = (o.input||0)+(o.output||0)+(o.cache_create||0)+(o.cache_read||0);
  return '<div class="tchip"><span class="tk">'+esc(name)+'</span><b>'+usd(o.cost)+'</b>'
    + '<span class="sub">'+fmtTok(tk)+' tok</span></div>';
}
function zeroDay(){ return {entries:0,input:0,output:0,cache_create:0,cache_read:0,cost:0,unknown:0}; }
function renderTokMeta(){
  var b = el('btn-tok-scan'), sc = el('tok-scanned');
  if(!TOK){ sc.textContent = ''; return; }
  b.hidden = !TOK.enabled;
  if(TOK.scanning){
    var pr = TOK.progress || {};
    b.disabled = true; b.innerHTML = '<span class="spin"></span> 스캔 중';
    sc.textContent = pr.total ? pr.done+'/'+pr.total : '';
  } else {
    b.disabled = false; b.innerHTML = '재스캔';
    sc.textContent = TOK.scanned_at ? '스캔 '+ago(ms(TOK.scanned_at)) : '';
  }
}
function renderTok(){
  var host = el('tok-body');
  renderTokMeta();
  if(!TOK){ host.innerHTML = '<p class="hint">불러오는 중…</p>'; return; }
  var T = TOK.total || zeroDay(), days = TOK.days || [];
  if(TOK.scanning && !T.entries){
    var pr = TOK.progress || {};
    host.innerHTML = '<div class="tok-note"><span class="spin"></span> 첫 스캔 중 ('+(pr.done||0)+'/'+(pr.total||0)+') - JSONL 파일을 읽고 있습니다</div>';
    return;
  }
  if(!days.length){
    host.innerHTML = '<p class="hint">'+(TOK.error ? '스캔 오류: '+esc(TOK.error)
      : '집계된 사용 기록이 없습니다. 재스캔으로 ~/.claude/projects 를 읽어 보세요.')+'</p>';
    return;
  }
  var byDate = {}; days.forEach(function(d){ byDate[d.date] = d; });
  var nowT = Date.now(), dw = TOK.days_window || TOK_DAYS;
  var today = byDate[dstr(nowT)] || zeroDay();
  var w7 = zeroDay();
  for(var i=0;i<7;i++){
    var dd = byDate[dstr(nowT-i*86400e3)];
    if(dd) ['entries','input','output','cache_create','cache_read','cost','unknown'].forEach(function(k){ w7[k] += dd[k]||0; });
  }
  var maxC = 0; days.forEach(function(d){ if(d.cost>maxC) maxC = d.cost; });
  var bars = '';
  for(var j=dw-1;j>=0;j--){
    var ds = dstr(nowT-j*86400e3), dv = byDate[ds];
    var cost = dv ? dv.cost : 0;
    var tk = dv ? (dv.input+dv.output+dv.cache_create+dv.cache_read) : 0;
    var hpx = (maxC>0 && cost>0) ? Math.max(2, Math.round(cost/maxC*68)) : 1;
    bars += '<i class="'+(j===0?'now':'')+(cost>0?'':' zero')+'" style="height:'+hpx+'px" title="'
      + esc(ds+' · '+usd(cost)+' · '+fmtTok(tk)+' tok'+(dv&&dv.unknown ? ' · 단가 미상 '+dv.unknown+'건' : ''))+'"></i>';
  }
  var cells = function(m, name){
    return '<td class="tm" title="'+esc(name)+'">'+esc(name)+'</td>'
      + '<td>'+fmtTok(m.input)+'</td><td>'+fmtTok(m.output)+'</td>'
      + '<td class="cc">'+fmtTok(m.cache_create)+'</td><td class="cc">'+fmtTok(m.cache_read)+'</td>'
      + '<td class="cx">'+fmtTok((m.cache_create||0)+(m.cache_read||0))+'</td>'
      + '<td class="tc">'+usd(m.cost)+'</td>';
  };
  var mrows = (TOK.models||[]).map(function(m){ return '<tr>'+cells(m, m.model)+'</tr>'; }).join('');
  host.innerHTML =
      '<div class="tok-left">'
    +   '<div class="tchips">'+tokChip('오늘', today)+tokChip('최근 7일', w7)+tokChip('전체 '+dw+'일', T)+'</div>'
    +   '<div class="tok-chart">'+bars+'</div>'
    +   '<div class="tok-axis"><span>'+esc(dstr(nowT-(dw-1)*86400e3).slice(5))+'</span><span>오늘</span></div>'
    + '</div>'
    + '<div class="tok-right">'
    +   '<table class="tok-table"><thead><tr><th>모델</th><th>입력</th><th>출력</th>'
    +   '<th class="cc">캐시 생성</th><th class="cc">캐시 읽기</th><th class="cx">캐시</th><th>비용</th></tr></thead>'
    +   '<tbody>'+mrows+'<tr class="sum">'+cells(T, '합계')+'</tr></tbody></table>'
    +   (T.unknown ? '<p class="hint tok-unk">단가 미상 엔트리 '+T.unknown+'건 - 해당 비용은 합계에서 제외</p>' : '')
    +   (TOK.error ? '<p class="hint tok-unk">스캔 오류: '+esc(TOK.error)+'</p>' : '')
    + '</div>';
}

// ── 히스토리·토큰 로드 - 로컬 저장소만 읽는 GET, 프로브 0회 ──────────
function loadHist(){
  return api('/api/history?hours='+HIST_HOURS).then(function(r){
    HIST = r.series || {};
    if(S && !menuOpen()) renderCards();
  }).catch(function(){});
}
function loadTok(){
  return api('/api/tokens?days='+TOK_DAYS).then(function(r){
    TOK = r; renderTok();
    clearTimeout(tokTimer);
    if(r.scanning) tokTimer = setTimeout(loadTok, 3e3);   // 스캔이 도는 동안 3초 폴링
  }).catch(function(){});
}

function menuOpen(){ return !!document.querySelector('#cards details[open]'); }
function render(skipCards){
  if(!S) return;
  renderTop(); renderActiveBar(); renderAlerts(); syncSettings();
  if(!skipCards) renderCards();
  renderTimeline(); renderDoctor(); renderLog();
}

// ── 토스트·에러 ───────────────────────────────────────────────────
var tt;
function toast(m, bad){ var t=el('toast'); t.textContent=m; t.className='toast show'+(bad?' bad':''); clearTimeout(tt); tt=setTimeout(function(){ t.className='toast'; }, 3200); }
function showErr(m){
  var e=el('err');
  if(!m){ e.hidden=true; e.innerHTML=''; return; }
  e.hidden=false;
  e.innerHTML = '<b>서버 통신 실패</b><span>'+esc(m)+' · 로컬 서버(<span class="mono">uv run --script server.py</span>)가 떠 있는지 확인하세요. 화면 값은 마지막으로 받은 상태입니다.</span>';
  var dot = el('conn').querySelector('.dot'); if(dot) dot.className = 'dot off';
}

// ── 상태 로드 ─────────────────────────────────────────────────────
function load(quiet){
  return api('/api/state').then(function(st){ RAW=st; S=toView(st); showErr(''); render(quiet && menuOpen()); return st; })
    .catch(function(e){ showErr(e.message); throw e; });
}
function act(btn, label, fn){
  if(busy) return Promise.resolve();
  busy = true;
  var old = btn ? btn.innerHTML : null;
  if(btn){ btn.disabled = true; btn.innerHTML = '<span class="spin"></span>'; }
  return fn().then(function(res){
    if(res && res.state){ RAW=res.state; S=toView(res.state); render(); } else { return load(); }
  }).then(function(){ toast(label+' 완료'); })
    .catch(function(e){ toast(label+' 실패: '+e.message, true); if(btn){ btn.disabled=false; btn.innerHTML=old; } })
    .then(function(){ busy=false; if(btn && document.body.contains(btn)){ btn.disabled=false; btn.innerHTML=old; } });
}
function copy(s){ if(navigator.clipboard && navigator.clipboard.writeText){ navigator.clipboard.writeText(s).then(function(){ toast('복사됨: '+s); }, function(){ toast(s); }); } else toast(s); }
function closeMenus(except){
  Array.prototype.forEach.call(document.querySelectorAll('details.menu[open]'), function(d){ if(d!==except) d.open = false; });
}

// ── 이벤트 ────────────────────────────────────────────────────────
document.addEventListener('click', function(e){
  var t = e.target;
  var sum = t.closest ? t.closest('details.menu>summary') : null;
  if(sum){ closeMenus(sum.parentNode); return; }
  if(!t.closest || !t.closest('details.menu')) closeMenus(null);

  var b = t.closest ? t.closest('button[data-act]') : null; if(!b) return;
  var a = b.getAttribute('data-act'), l = b.getAttribute('data-l');
  closeMenus(null);
  if(a==='copy'){ copy('cct '+l); return; }
  if(a==='usage') return act(b, l+' 갱신', function(){ return api('/api/refresh', {label:l}); }).then(loadHist);
  if(a==='check') return act(b, l+' 점검', function(){ return api('/api/check', {label:l}); });
  if(a==='use'){
    if(!confirm(l+' 를 활성(sticky) 계정으로 기록할까요?\n새 셸은 자동 적용, 열린 터미널은 cct refresh 가 필요합니다.')) return;
    return act(b, l+' 활성화', function(){ return api('/api/use', {label:l}).then(function(r){ toast('활성 = '+l+' · 열린 터미널에서는 cct refresh'); return r; }); });
  }
  if(a==='rename'){
    var n = prompt('새 라벨 (a-z0-9_)', l); if(n===null) return; n=n.trim().toLowerCase();
    var err = validLabel(n); if(err){ toast(err, true); return; }
    if(acc(n)){ toast(n+' 계정이 이미 존재함', true); return; }
    return act(b, '이름 변경', function(){ return api('/api/rename', {old:l, 'new':n}); });
  }
  if(a==='rm'){
    if(!confirm(l+' 계정을 삭제할까요?\n지갑 백업 후 잠금 트랜잭션으로 삭제됩니다.')) return;
    return act(b, l+' 삭제', function(){ return api('/api/rm', {label:l}); });
  }
});
document.addEventListener('keydown', function(e){
  if(e.key==='Escape'){ closeMenus(null); return; }
  // 임계 입력은 Enter 로도 저장한다(blur 위임 - 이중 발화 방지)
  if(e.key==='Enter' && e.target && (e.target.id==='in-warn' || e.target.id==='in-crit')) e.target.blur();
});
document.addEventListener('submit', function(e){
  if(e.target.id!=='form-add') return; e.preventDefault();
  var l = el('add-label').value.trim().toLowerCase();
  var ow = el('add-ow').checked;
  var body = {label:l, token: el('add-token').value, overwrite: ow};
  el('add-token').value='';
  var err = validLabel(l); if(err){ toast(err, true); return; }
  if(!body.token){ toast('토큰이 비어 있음', true); return; }
  var btn = e.target.querySelector('button[type=submit]');
  act(btn, l+' 등록', function(){ return api('/api/add', body); }).then(function(){ body.token=null; el('add-label').value=''; });
});
el('btn-refresh').addEventListener('click', function(){
  act(this, '전체 갱신', function(){ return api('/api/refresh', {all:true}); }).then(loadHist);
});
el('btn-off').addEventListener('click', function(){
  closeMenus(null);
  if(!confirm('cct off - 활성(sticky) 라벨을 해제할까요?\n라벨 없는 cct/claude 는 기본 라벨로 실행됩니다.')) return;
  act(null, '활성 해제', function(){ return api('/api/off', {}); });
});
el('sel-auto').addEventListener('change', function(){
  var v = +this.value;
  act(null, '자동갱신 설정', function(){ return api('/api/settings', {auto_min:v}); })
    .then(function(){ toast(v===0 ? '자동갱신 끔 - 수동 갱신만' : '자동갱신 '+v+'분 (하한 15분: 프로브가 사용량을 소비)'); });
});
el('chk-write').addEventListener('change', function(){
  document.body.classList.toggle('write', this.checked);
  try { sessionStorage.setItem('cct-write', this.checked ? '1':'0'); } catch(_){}
  toast(this.checked ? '쓰기 모드 켬 - 토큰 값은 화면·로그에 표시되지 않음' : '쓰기 모드 끔 (읽기 전용)');
});
el('sel-hist').addEventListener('change', function(){ HIST_HOURS = +this.value || 24; loadHist(); });
el('sel-tok-days').addEventListener('change', function(){ TOK_DAYS = +this.value || 30; loadTok(); });
el('btn-tok-scan').addEventListener('click', function(){
  this.disabled = true;
  api('/api/tokens/scan', {}).then(function(){ toast('재스캔 시작 - 디스크 읽기만, 프로브 0회'); return loadTok(); })
    .catch(function(e){ toast('재스캔 실패: '+e.message, true); renderTokMeta(); });
});
el('in-warn').addEventListener('blur', pushThresholds);
el('in-crit').addEventListener('blur', pushThresholds);
el('sel-notify').addEventListener('change', function(){
  var v = this.value, names = {off:'끔', crit:'위험만', warn:'주의부터'};
  api('/api/settings', {notify:v}).then(function(r){
    if(r.state){ RAW = r.state; S = toView(r.state); }
    toast('macOS 알림: '+(names[v]||v));
  }).catch(function(e){ toast('알림 설정 실패: '+e.message, true); syncSettings(); });
});

// ── 기동 ──────────────────────────────────────────────────────────
var w0 = false;
try { w0 = sessionStorage.getItem('cct-write')==='1'; } catch(_){}
if(/[?&]write=1/.test(location.search)) w0 = true;
if(w0){ el('chk-write').checked = true; document.body.classList.add('write'); }
load().catch(function(){});
loadHist(); loadTok();
setInterval(function(){ if(!busy) load(true).catch(function(){}); }, 30e3);
setInterval(function(){ if(S){ renderTop(); renderActiveBar(); renderAlerts(); renderTokMeta(); if(!menuOpen()) renderCards(); renderTimeline(); } }, 60e3);
setInterval(loadHist, 300e3);                                        // 히스토리 5분 주기 - 로컬 sqlite 읽기만
setInterval(function(){ if(!(TOK && TOK.scanning)) loadTok(); }, 600e3);   // 토큰 10분 주기
})();
