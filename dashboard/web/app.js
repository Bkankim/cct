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
    providers: st.providers || [],
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
  out.push('<span class="lk">5h <b>'+(five.used_percentage===undefined?'-':Math.round(five.used_percentage)+'%')+'</b>'
    + (five.resets_at?' <span>'+remaining(ms(five.resets_at))+'</span>':'')+'</span>');
  out.push('<span class="lk">7d <b>'+(seven.used_percentage===undefined?'-':Math.round(seven.used_percentage)+'%')+'</b>'
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
  return '<article class="'+cls+'" data-l="'+esc(a.label)+'" title="눌러서 '+esc(a.label)+' 상세 보기"><div class="ac-head">'+provLogo('claude')+'<a class="lbl" href="#/account/'+esc(a.label)+'" title="'+esc(a.label)+' 상세">'+esc(a.label)+'</a>'
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

// ── 프로바이더(GPT·Grok) - OAuth 온보딩 카드 + 사용률 미터 ───────────
// 사용량 조회는 메타데이터 GET 이라 소비 0. 로고는 인라인 SVG(외부 리소스 없음).
var PROV_LOGOS = {
  claude: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.583.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z"/></svg>',
  openai: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.8956zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997z"/></svg>',
  xai: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="m3.005 8.858 8.783 12.544h3.904L6.908 8.858zM6.905 15.825 3 21.402h3.907l1.951-2.788zM16.585 2l-6.75 9.64 1.953 2.79L20.492 2zM17.292 7.965v13.437h3.2V3.395z"/></svg>'
};
var PROV_STALE_MS = 15*M;      // usage_at 이 이보다 오래되면 자동 재조회
function provWin(w){
  if(!w || w.used_pct===null || w.used_pct===undefined) return null;
  return {u: w.used_pct/100, r: ms(w.reset_at), s: null};
}
function provLogo(id){ return '<span class="plogo p-'+esc(id)+'">'+(PROV_LOGOS[id]||'')+'</span>'; }
function provJoinCard(p){
  var body;
  if(p.login_pending){
    body = '<span class="hint">브라우저에서 로그인 진행 중 - 완료하면 이 카드가 사용량으로 바뀝니다</span>'
      + '<form class="prov-code" data-p="'+esc(p.id)+'">'
      + '<input type="text" placeholder="리다이렉트가 안 되면 화면의 코드 붙여넣기" autocomplete="off">'
      + '<button class="btn sm" type="submit">확인</button></form>'
      + '<button class="btn sm ghost" data-act="prov-login" data-p="'+esc(p.id)+'">다시 시도</button>';
  } else {
    body = '<button class="btn accent" data-act="prov-login" data-p="'+esc(p.id)+'">'+esc(p.name)+' 계정 연결</button>';
  }
  return '<article class="acct prov"><div class="prov-join">'
    + provLogo(p.id)
    + '<span class="pname">'+esc(p.name)+'</span><span class="pvendor">'+esc(p.vendor)+'</span>'
    + body
    + (p.login_error ? '<span class="perr">'+esc(p.login_error)+'</span>' : '')
    + '<span class="pnote">브라우저 OAuth 로그인 · 토큰은 이 기기(mode 600)에만 저장 · 비공식 조회라 정책 변경 시 끊길 수 있음</span>'
    + '</div></article>';
}
function provCard(p){
  if(!p.connected) return provJoinCard(p);
  var u = p.usage || null, w = (u && u.windows) || {};
  var badges = '';
  if(u && u.plan) badges += '<span class="badge acc">'+esc(u.plan)+'</span>';
  if(p.usage_error) badges += '<span class="badge bad" title="'+esc(p.usage_error.message||'')+'">조회 실패</span>';
  var body;
  if(p.id==='openai'){
    body = metric('5h', provWin(w['5h']), false) + metric('7d', provWin(w['7d']), true);
  } else {
    body = metric('wk', provWin(w['weekly']), true);
    if(u && u.products && u.products.length){
      body += '<div class="ac-note">'+u.products.map(function(x){
        return esc(x.name)+' '+esc(String(x.used_pct))+'%'; }).join(' · ')+'</div>';
    }
  }
  if(!u && !p.usage_error) body = naMetric(p.id==='openai'?'5h':'wk', '미확인', false);
  if(p.usage_error && !u) body = naMetric(p.id==='openai'?'5h':'wk', '조회 실패', true);
  var meta = '<div class="ac-meta">'
    + '<span class="mi">확인 <b>'+(p.usage_at?ago(ms(p.usage_at)):'미확인')+'</b></span>'
    + (p.email ? '<span class="mi">계정 <b>'+esc(p.email)+'</b></span>' : '')
    + '</div>';
  var act = '<div class="ac-act">'
    + '<button class="btn sm" data-act="prov-refresh" data-p="'+esc(p.id)+'" title="메타데이터 조회만 - 사용량 소비 0">갱신</button>'
    + '<button class="btn sm ghost" data-act="prov-logout" data-p="'+esc(p.id)+'">연결 해제</button>'
    + '</div>';
  return '<article class="acct prov"><div class="ac-head">'+provLogo(p.id)
    + '<span class="lbl">'+esc(p.name)+'</span>'
    + '<span class="ac-badges">'+badges+'</span></div>'
    + '<div class="ac-metrics">'+body+'</div>'+meta+act+'</article>';
}
function renderProviders(){
  var host = el('providers');
  if(!host) return;
  var P = S.providers || [];
  host.innerHTML = P.length ? P.map(provCard).join('')
    : '<div class="empty"><b>프로바이더 추적이 꺼져 있습니다</b><span>서버를 --no-providers 없이 실행하면 GPT·Grok 카드가 표시됩니다.</span></div>';
}
var provPoll = null;
function startProvPoll(){
  // 로그인 콜백은 서버가 받으므로, 완료를 상태 폴링으로 감지한다(최대 2분).
  var ticks = 0;
  clearInterval(provPoll);
  provPoll = setInterval(function(){
    ticks++;
    var pending = S && S.providers.some(function(p){ return p.login_pending; });
    var joined = S && S.providers.every(function(p){ return !p.login_pending; });
    if(ticks>40 || (!pending && joined && ticks>1)){ clearInterval(provPoll); provPoll=null; }
    if(!busy) load(true).catch(function(){});
  }, 3e3);
}
function provAutoRefresh(){
  if(!S || S.server.fake) return;
  var stale = S.providers.some(function(p){
    return p.connected && (!p.usage_at || Date.now()-ms(p.usage_at) > PROV_STALE_MS);
  });
  if(!stale) return;
  api('/api/providers/refresh', {force:false}).then(function(){ return load(true); }).catch(function(){});
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
  var ap = el('chk-active-probe');
  if(ap) ap.checked = st.active_probe !== false;
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
    if(DET_LABEL) loadDetail();          // 조회 직후 상세의 사용률 기록도 갱신
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
  renderProviders(); renderTimeline(); renderDoctor(); renderLog();
  if(DET_LABEL) renderDetail();
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
  if(a==='prov-login'){
    var pid = b.getAttribute('data-p');
    return act(b, '로그인 시작', function(){
      return api('/api/providers/login', {provider: pid}).then(function(r){
        var url = r.login && r.login.auth_url;
        if(url){
          var w = window.open(url, '_blank');
          if(!w) toast('팝업이 차단됨 - 브라우저에서 팝업을 허용하세요', true);
          startProvPoll();
        }
        return r;
      });
    });
  }
  if(a==='prov-refresh'){
    var pid2 = b.getAttribute('data-p');
    return act(b, '사용량 갱신', function(){ return api('/api/providers/refresh', {provider: pid2, force: true}); });
  }
  if(a==='prov-logout'){
    var pid3 = b.getAttribute('data-p');
    if(!confirm(pid3+' 연결을 해제할까요?\n저장된 토큰이 삭제되며 다시 로그인해야 추적됩니다.')) return;
    return act(b, '연결 해제', function(){ return api('/api/providers/logout', {provider: pid3}); });
  }
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
  if(e.target.classList && e.target.classList.contains('prov-code')){
    e.preventDefault();
    var pid = e.target.getAttribute('data-p');
    var input = e.target.querySelector('input');
    var codeVal = input.value.trim();
    if(!codeVal){ toast('코드가 비어 있음', true); return; }
    input.value = '';
    var btn = e.target.querySelector('button[type=submit]');
    act(btn, '코드 확인', function(){ return api('/api/providers/code', {provider: pid, code: codeVal}); });
    return;
  }
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
el('chk-active-probe').addEventListener('change', function(){
  var v = this.checked;
  api('/api/settings', {active_probe: v}).then(function(r){
    if(r.state){ RAW = r.state; S = toView(r.state); }
    toast(v ? '세션 중 5분 조회 켬 - 조회가 사용량을 조금 소비' : '세션 중 5분 조회 끔');
  }).catch(function(e){ toast('설정 실패: '+e.message, true); syncSettings(); });
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

// ── 계정 상세 (#/account/<라벨>) ─────────────────────────────────────
// 세션 훅(cct-session-hook.sh) 기록으로 이 맥의 메시지를 계정에 귀속한 /api/account 를 그린다.
var DET = null, DET_LABEL = null, DET_RANGE = 24, DET_REQ = {};
var DET_DAYS = 7, WIN5 = 5*H;
function modelName(m){
  var s = String(m||'').replace(/^claude-/, '').replace(/-\d{8}$/, '').split('-');
  if(!s[0]) return '-';
  return s[0].charAt(0).toUpperCase()+s[0].slice(1)+(s.length>1 ? ' '+s.slice(1).join('.') : '');
}
function modelColor(m){
  if(/opus/.test(m)) return 'var(--m-opus)';
  if(/sonnet/.test(m)) return 'var(--m-sonnet)';
  if(/haiku/.test(m)) return 'var(--m-haiku)';
  return 'var(--fg-dim)';
}
function toneOf(p){ return p>=CRIT_AT ? 'bad' : p>=WARN_AT ? 'warn' : 'ok'; }
function hm(ts){ return clock(ts, false); }
function mdhm(ts){ var d=new Date(ts); return (d.getMonth()+1)+'/'+d.getDate()+' '+hm(ts); }
function durTxt(sec){ var h=Math.floor(sec/3600), m=Math.round(sec%3600/60); return h ? h+'시간 '+m+'분' : m+'분'; }
function detRoute(){
  var m = /^#\/account\/([a-z0-9_]+)$/.exec(location.hash);
  el('main').hidden = !!m; el('detail').hidden = !m;
  if(!m){ DET_LABEL = null; return; }
  if(DET_LABEL !== m[1]){ DET_LABEL = m[1]; DET = null; DET_REQ = {}; window.scrollTo(0, 0); }
  renderDetail(); loadDetail();
}
function loadDetail(){
  var l = DET_LABEL; if(!l) return Promise.resolve();
  return api('/api/account?label='+encodeURIComponent(l)+'&days='+DET_DAYS).then(function(r){
    if(l !== DET_LABEL) return;
    DET = r; renderDetail();
  }).catch(function(e){ if(l === DET_LABEL) toast('상세 불러오기 실패: '+e.message, true); });
}
function tile(k, v, bar, d){
  return '<div class="dt-tile"><span class="k">'+k+'</span><span class="v">'+v+'</span>'+(bar||'')+'<span class="d">'+d+'</span></div>';
}
function utilTile(name, w, withDate){
  if(!w || w.u===null || w.u===undefined) return tile(name, '-', '', '미확인');
  var p = Math.round(w.u*100);
  return tile(name, p+'<small>%</small>',
    '<div class="dt-bar"><i style="width:'+Math.min(100,p)+'%;background:var(--'+toneOf(p)+')"></i></div>',
    w.r ? '초기화 '+clock(w.r, withDate)+' · '+remaining(w.r)+' 남음' : '초기화 -');
}
function detHead(a){
  var l = DET_LABEL, badges = '';
  if(a && a.isActive) badges += '<span class="badge acc"><i class="dot on"></i>활성</span>';
  if(a && a.isDefault) badges += '<span class="badge">기본</span>';
  if(a && a.w5 && a.w5.s==='rejected') badges += '<span class="badge bad">5h 차단</span>';
  var meta = a ? '<span class="dt-meta">org <b>'+esc(a.org||'-')+'</b> · 7d 초기화 <b>'+(a.w7&&a.w7.r?clock(a.w7.r,true):'-')
    +'</b> · 마지막 조회 <b>'+(a.probeAt?ago(a.probeAt):'-')+'</b></span>' : '';
  var dis = a && a.token ? '' : ' disabled';
  return '<header class="topbar dt-top"><a class="dt-back" href="#">← 대시보드</a>'
    + '<div class="dt-acct">'+provLogo('claude')+'<h1>'+esc(l)+'</h1>'+badges+meta+'</div>'
    + '<div class="tctl"><button class="btn sm" data-act="check" data-l="'+esc(l)+'"'+dis+'>토큰 점검</button>'
    + '<button class="btn sm" data-act="usage" data-l="'+esc(l)+'"'+dis+' title="cct usage - 실프로브라 사용량을 소비합니다">지금 조회</button></div></header>';
}
function detTiles(a){
  var ins = DET ? DET.insights : {}, sum = DET ? DET.summary : null;
  var eta = ins && ins.eta_5h ? ms(ins.eta_5h) : null;
  var etaTile = eta
    ? tile('5h 도달 예상', hm(eta), '', '최근 조회 두 번의 속도 유지 시 · 초기화 '+(a&&a.w5&&a.w5.r?fmtDur(a.w5.r-eta)+' 전':'-'))
    : tile('5h 도달 예상', '-', '', '이 속도면 초기화 전에 닿지 않거나 조회 기록 부족');
  return '<div class="dt-tiles">'
    + utilTile('5시간', a && a.w5, false) + utilTile('7일', a && a.w7, true) + utilTile('7일 Opus', a && a.wf, true)
    + etaTile + planTile(sum)
    + '</div>';
}
// 이번 달 API 환산과 월 구독료 대비 배수. 구독료는 계정별 설정(서버 state)에 둔다.
function planTile(sum){
  var p = DET && DET.plan;
  if(!p) return tile('이번 달 API 환산', '-', '', '불러오는 중');
  var mult = p.multiple===null || p.multiple===undefined ? '' : ' · 구독료 대비 <b>'+p.multiple.toFixed(p.multiple<1 ? 2 : 1)+'배</b>';
  var form = '<form class="dt-plan"><span>월 구독료 $</span><input type="number" min="1" max="10000" step="1" value="'+(p.usd||'')+'" placeholder="미입력" aria-label="월 구독료(USD)">'
    + '<button class="btn sm" type="submit">저장</button></form>';
  return tile('이번 달 API 환산', usd(p.month_cost), '',
    (p.usd ? '구독료 $'+p.usd+mult : '구독료를 입력하면 배수를 보여줍니다')
    + (sum ? '<br>최근 '+DET_DAYS+'일 요청 '+sum.requests+' · 세션 '+sum.sessions : '') + form);
}
// 사용률 선 + 모델별 토큰 막대 + 외부 사용 음영 + 한도 도달 점
function detChart(){
  var host = el('dt-chart'); if(!host || !DET) return;
  var W = Math.max(560, host.clientWidth), Hh = 250, L = 36, R = 8, T = 10, B = 24;
  var iw = W-L-R, ih = Hh-T-B, now = Date.now(), t0 = now - DET_RANGE*H;
  function X(t){ return L + (t-t0)/(now-t0)*iw; }
  function Y(u){ return T + ih - ih*Math.max(0, Math.min(1, u)); }
  var bsec = DET.bucket_sec*1000, bw = Math.max(1, bsec/(now-t0)*iw);
  var bk = DET.buckets.filter(function(b){ return b.at*1000 >= t0 - bsec; });
  var maxTok = 1; bk.forEach(function(b){ maxTok = Math.max(maxTok, b.tokens); });
  var hist = DET.history.map(function(h){ return {at:h[0]*1000, u:h[1], r:h[4]}; })
                        .filter(function(h){ return h.u!==null && h.at >= t0 - WIN5; });
  var s = '';
  [0,.25,.5,.75,1].forEach(function(p){
    s += '<line x1="'+L+'" x2="'+(W-R)+'" y1="'+Y(p)+'" y2="'+Y(p)+'" stroke="var(--line-soft)"/>'
      + '<text x="'+(L-5)+'" y="'+(Y(p)+3.5)+'" fill="var(--fg-dim)" font-size="10" text-anchor="end">'+(p*100)+'%</text>';
  });
  // 외부 사용 음영: 같은 창의 연속 조회 사이 사용률이 올랐는데 그 사이 로컬 토큰이 0
  for(var i=1;i<hist.length;i++){
    var a = hist[i-1], b = hist[i];
    if(a.r !== b.r || b.u - a.u < 0.02 || b.at < t0) continue;
    var local = bk.some(function(x){ var t=x.at*1000; return t+bsec > a.at && t < b.at && x.tokens > 0; });
    if(!local) s += '<rect x="'+X(Math.max(a.at,t0))+'" y="'+T+'" width="'+Math.max(2, X(b.at)-X(Math.max(a.at,t0)))+'" height="'+ih+'" fill="var(--ext)"/>';
  }
  DET.windows.forEach(function(w){
    var st = (w.reset*1000) - WIN5;
    if(st > t0) s += '<line x1="'+X(st)+'" x2="'+X(st)+'" y1="'+T+'" y2="'+(T+ih)+'" stroke="var(--line-strong)" stroke-dasharray="2 3"/>';
  });
  bk.forEach(function(b){
    var x = X(b.at*1000), y0 = T+ih;
    Object.keys(b.models).sort().forEach(function(m){
      var h = ih*.55*b.models[m]/maxTok; if(h <= 0) return; y0 -= h;
      s += '<rect x="'+(x+bw*.1)+'" y="'+y0+'" width="'+Math.max(1, bw*.8)+'" height="'+h+'" fill="'+modelColor(m)+'" opacity=".78"/>';
    });
  });
  // 사용률 선: 창이 바뀌면 이전 창 초기화 시각에 0 으로 떨어뜨린다
  var pts = [], prev = null;
  hist.forEach(function(h){
    if(prev && h.r !== prev.r && prev.r && prev.r*1000 <= h.at){
      pts.push([prev.r*1000, prev.u], [prev.r*1000, 0], [Math.max(prev.r*1000, h.r*1000 - WIN5), 0]);
    }
    pts.push([h.at, h.u]); prev = h;
  });
  if(prev) pts.push([prev.r && prev.r*1000 < now ? prev.r*1000 : now, prev.u]);
  pts = pts.filter(function(p){ return p[0] >= t0; });
  if(pts.length > 1)
    s += '<path d="'+pts.map(function(p,j){ return (j?'L':'M')+X(p[0]).toFixed(1)+' '+Y(p[1]).toFixed(1); }).join(' ')+'" fill="none" stroke="var(--fg)" stroke-width="1.5"/>';
  DET.windows.forEach(function(w){
    if(w.hit_at && w.hit_at*1000 >= t0) s += '<circle cx="'+X(w.hit_at*1000)+'" cy="'+Y(1)+'" r="4" fill="var(--bad)"><title>한도 도달 '+mdhm(w.hit_at*1000)+'</title></circle>';
  });
  var step = DET_RANGE <= 24 ? 3*H : D;
  for(var t = Math.ceil(t0/step)*step; t < now; t += step){
    var d = new Date(t), lbl = DET_RANGE <= 24 ? pad(d.getHours())+':00' : (d.getMonth()+1)+'/'+d.getDate();
    if(DET_RANGE > 24){ d.setHours(0,0,0,0); t = d.getTime(); if(t < t0) continue; }
    s += '<text x="'+X(t)+'" y="'+(Hh-7)+'" fill="var(--fg-dim)" font-size="10" text-anchor="middle">'+lbl+'</text>';
  }
  if(!hist.some(function(h){ return h.at >= t0; }))
    s += '<text class="dt-empty" x="'+(L+iw/2)+'" y="'+(T+18)+'" text-anchor="middle">이 기간에 사용률 조회 기록이 없습니다 - 카드의 갱신이나 자동 갱신으로 쌓입니다</text>';
  s += '<rect class="dt-hit" x="'+L+'" y="'+T+'" width="'+iw+'" height="'+ih+'" fill="transparent"/>';
  host.innerHTML = '<svg width="'+W+'" height="'+Hh+'" viewBox="0 0 '+W+' '+Hh+'">'+s+'</svg>';
  var hit = host.querySelector('.dt-hit'), tip = el('dt-tip');
  hit.onmousemove = function(e){
    var r = host.querySelector('svg').getBoundingClientRect(), t = t0 + (e.clientX - r.left - L)/iw*(now-t0);
    var b = bk.filter(function(x){ return x.at*1000 <= t && t < x.at*1000 + bsec; })[0];
    var h = null; hist.forEach(function(x){ if(x.at <= t) h = x; });
    var rows = '<b>'+mdhm(t)+'</b>'+(h ? ' · 5h '+pct(h.u)+' <span class="hint">('+ago(h.at)+' 조회)</span>' : '');
    if(b) rows += '<br>'+Object.keys(b.models).map(function(m){ return modelName(m)+' '+fmtTok(b.models[m]); }).join(' · ')+' · '+usd(b.cost);
    tip.innerHTML = rows; tip.hidden = false;
    tip.style.left = Math.min(e.clientX+12, innerWidth-260)+'px'; tip.style.top = (e.clientY+12)+'px';
  };
  hit.onmouseleave = function(){ tip.hidden = true; };
}
function detLegend(){
  var ms_ = {};
  DET.buckets.forEach(function(b){ Object.keys(b.models).forEach(function(m){ ms_[m] = 1; }); });
  return Object.keys(ms_).sort().map(function(m){ return '<span><i class="sw" style="background:'+modelColor(m)+'"></i>'+esc(modelName(m))+'</span>'; }).join('')
    + '<span><i class="sw" style="background:var(--fg)"></i>5h 사용률</span>'
    + '<span><i class="sw" style="background:var(--ext)"></i>외부 사용 추정</span>'
    + '<span><i class="sw" style="background:var(--bad);border-radius:50%"></i>한도 도달</span>';
}
function detWindows(){
  var rows = DET.windows.filter(function(w){ return w.requests || w.peak > 0; }).slice(0, 12).map(function(w){
    var st = w.reset*1000 - WIN5, p = Math.floor(w.peak*100), ext = w.external_pct;
    return '<tr><td class="tm">'+mdhm(st)+' - '+hm(w.reset*1000)+(w.active?' <span class="badge acc">진행 중</span>':'')+'</td>'
      + '<td class="'+toneOf(p)+'">'+p+'%</td>'
      + '<td>'+(w.hit_at?'<span class="badge bad">'+hm(w.hit_at*1000)+' 도달</span>':'<span class="dim">-</span>')+'</td>'
      + '<td>'+w.sessions+'</td><td>'+fmtTok(w.input+w.output+w.cache_create+w.cache_read)+'</td>'
      + '<td class="'+(ext?'warn':'dim')+'">'+(ext===null||ext===undefined ? '기록 전' : ext>=1 ? '+'+Math.round(ext)+'%p' : '-')+'</td>'
      + '<td>'+usd(w.cost)+'</td></tr>';
  }).join('');
  return rows ? '<div class="dt-scroll"><table class="tok-table dt-table"><thead><tr><th>구간</th><th>최고</th><th>한도</th><th>세션</th><th>로컬 토큰</th><th>외부 추정</th><th>API 환산</th></tr></thead><tbody>'+rows+'</tbody></table></div>'
    : '<p class="hint">조회 기록이 없습니다. 카드에서 갱신하거나 자동 갱신을 켜면 쌓입니다.</p>';
}
function mixBar(models){
  var tot = 0; Object.keys(models).forEach(function(m){ tot += models[m]; });
  return '<span class="dt-mix">'+Object.keys(models).sort().map(function(m){
    return '<i style="width:'+(models[m]/tot*100)+'%;background:'+modelColor(m)+'" title="'+esc(modelName(m))+' '+models[m]+'건"></i>'; }).join('')+'</span>';
}
function reqTable(sid){
  var r = DET_REQ[sid];
  if(!r) return '<p class="hint">불러오는 중…</p>';
  if(!r.length) return '<p class="hint">요청 없음</p>';
  return '<table class="tok-table"><thead><tr><th>시각</th><th>모델</th><th>입력</th><th>캐시 쓰기</th><th>캐시 읽기</th><th>출력</th><th>API 환산</th></tr></thead><tbody>'
    + r.map(function(q){ return '<tr><td class="tm">'+mdhm(q.at*1000)+'</td><td>'+esc(modelName(q.model))+'</td><td>'+fmtTok(q.input)+'</td><td>'+fmtTok(q.cache_create)
      +'</td><td>'+fmtTok(q.cache_read)+'</td><td>'+fmtTok(q.output)+'</td><td class="tc">'+usd(q.cost)+'</td></tr>'; }).join('')
    + '</tbody></table>';
}
function detSessions(){
  if(!DET.sessions.length) return '<p class="hint">이 계정으로 귀속된 세션이 아직 없습니다. 세션 훅이 설치된 뒤 <code>cct</code> 로 실행한 세션부터 집계됩니다.</p>';
  var now = Date.now();
  return '<div class="dt-scroll"><table class="tok-table dt-table dt-ses"><thead><tr><th>시작</th><th>프로젝트</th><th>시간</th><th>모델</th><th>요청</th><th>입력</th><th>출력</th><th>캐시 읽기</th><th>API 환산</th><th>한도 에러</th></tr></thead><tbody>'
    + DET.sessions.map(function(s){
      var open = DET_REQ.hasOwnProperty(s.session) && DET_REQ['open:'+s.session];
      var live = now - s.end*1000 < 10*M;
      return '<tr class="dt-row'+(open?' open':'')+'" data-sid="'+esc(s.session)+'"><td class="tm"><span class="caret">▸</span> '+mdhm(s.start*1000)
        + ' <span class="dim">'+esc(s.session.slice(0,8))+'</span></td><td class="tm">'+esc(s.project)+'</td>'
        + '<td>'+durTxt(s.end-s.start)+(live?' <span class="badge acc">진행 중</span>':'')+'</td><td>'+mixBar(s.models)+'</td>'
        + '<td>'+s.requests+'</td><td>'+fmtTok(s.input+s.cache_create)+'</td><td>'+fmtTok(s.output)+'</td><td>'+fmtTok(s.cache_read)+'</td>'
        + '<td class="tc">'+usd(s.cost)+'</td><td class="'+(s.limit_errors?'bad':'dim')+'">'+(s.limit_errors||'-')+'</td></tr>'
        + (open ? '<tr class="dt-sub"><td colspan="10"><div class="dt-req">'+reqTable(s.session)+'</div></td></tr>' : '');
    }).join('') + '</tbody></table></div>';
}
function hbars(rows, key, colorOf){
  if(!rows.length) return '<p class="hint">데이터 없음</p>';
  var max = Math.max.apply(null, rows.map(function(r){ return r.cost; })) || 1;
  return rows.slice(0, 8).map(function(r){
    return '<div class="dt-hb"><span class="lbl">'+esc(key(r))+'</span><div class="dt-bar big"><i style="width:'+(r.cost/max*100)+'%;background:'+colorOf(r)+'"></i></div><span class="val">'+usd(r.cost)+'</span></div>';
  }).join('');
}
function detInsights(){
  var ins = DET.insights, top = DET.sessions.slice().sort(function(a,b){ return b.cache_read-a.cache_read; })[0];
  var hits = DET.windows.filter(function(w){ return w.hit_at; }).map(function(w){ return mdhm(w.hit_at*1000); });
  function card(k, v, d){ return '<div class="dt-card"><span class="k">'+k+'</span><span class="v">'+v+'</span><span class="d">'+d+'</span></div>'; }
  return card('5h 1%당 토큰', ins.tokens_per_pct ? '≈ '+fmtTok(ins.tokens_per_pct) : '-', '로컬 사용이 있는 창 중 외부 사용이 가장 적은 창 기준 · 캐시 읽기 포함')
    + card('외부 사용 비율', ins.external_share===null ? '-' : pct(ins.external_share), '끝난 5h 창 사용률 중 이 맥 토큰으로 설명되지 않는 몫 · 웹·앱·다른 PC')
    + card('캐시 읽기 비중', ins.cache_read_share===null ? '-' : pct(ins.cache_read_share), top ? '최대 세션 '+esc(top.session.slice(0,8))+' '+fmtTok(top.cache_read) : '세션 없음')
    + card('한도 도달', ins.limit_hits+'회', hits.length ? hits.slice(0,3).join(' · ') : '최근 '+DET_DAYS+'일 없음');
}
function renderDetail(){
  var host = el('detail'); if(!DET_LABEL) return;
  if(host.contains(document.activeElement) && document.activeElement.tagName==='INPUT') return;   // 입력 중엔 다시 그리지 않는다
  var a = acc(DET_LABEL);
  if(!DET){ host.innerHTML = detHead(a)+'<p class="hint dt-loading">불러오는 중…</p>'; return; }
  var seg = '<span class="dt-seg"><button class="btn sm'+(DET_RANGE===24?' on':'')+'" data-range="24">24시간</button>'
          + '<button class="btn sm'+(DET_RANGE===168?' on':'')+'" data-range="168">7일</button></span>';
  host.innerHTML = detHead(a) + detTiles(a)
    + '<section class="panel"><div class="p-head"><h3>사용률 · 토큰 타임라인</h3><span class="hint">선 = 5h 사용률(조회 시점) · 막대 = 이 맥에서 '+esc(DET_LABEL)+'(으)로 쓴 토큰(15분) · 노란 음영 = 로컬 토큰 없이 사용률 상승</span>'+seg+'</div>'
    + '<div class="legend dt-legend">'+detLegend()+'</div><div class="p-body"><div class="dt-scroll" id="dt-chart"></div></div></section>'
    + '<section class="panel"><div class="p-head"><h3>5시간 구간 기록</h3><span class="hint">초기화 시각마다 끊은 구간 · 최근 '+DET_DAYS+'일</span></div><div class="p-body">'+detWindows()+'</div></section>'
    + '<section class="panel"><div class="p-head"><h3>세션</h3><span class="hint">'+esc(DET_LABEL)+'(으)로 실행된 세션 · 누르면 요청 단위로 펼침 (대화 내용은 표시하지 않음)</span></div><div class="p-body">'+detSessions()+'</div></section>'
    + '<div class="cols dt-cols"><section class="panel"><div class="p-head"><h3>모델별</h3><span class="hint">최근 '+DET_DAYS+'일 · API 환산</span></div><div class="p-body">'
    + hbars(DET.models, function(r){ return modelName(r.model); }, function(r){ return modelColor(r.model); }) + '</div></section>'
    + '<section class="panel"><div class="p-head"><h3>프로젝트별</h3><span class="hint">최근 '+DET_DAYS+'일 · API 환산</span></div><div class="p-body">'
    + hbars(DET.projects, function(r){ return r.project; }, function(){ return 'var(--accent)'; }) + '</div></section></div>'
    + '<section class="panel"><div class="p-head"><h3>분석</h3><span class="hint">최근 '+DET_DAYS+'일 · 추정치</span></div><div class="p-body dt-cards">'+detInsights()+'</div></section>'
    + '<p class="hint dt-foot">'+(DET.tracking_since ? '세션 기록 시작 '+mdhm(DET.tracking_since*1000)+' · ' : '세션 기록 없음 (훅 미설치) · ')
    + '이 맥에서 <code>cct</code> 로 실행한 Claude Code 세션만 계정별로 나뉩니다. 웹·앱·다른 PC 사용은 사용률 선과 외부 추정으로만 보입니다.</p>';
  detChart();
}
el('detail').addEventListener('click', function(e){
  var r = e.target.closest('[data-range]');
  if(r){ DET_RANGE = +r.getAttribute('data-range'); renderDetail(); return; }
  var row = e.target.closest('tr.dt-row'); if(!row) return;
  var sid = row.getAttribute('data-sid'), key = 'open:'+sid;
  DET_REQ[key] = !DET_REQ[key];
  if(DET_REQ[key] && !DET_REQ.hasOwnProperty(sid)){
    DET_REQ[sid] = null;
    api('/api/account?label='+encodeURIComponent(DET_LABEL)+'&days='+DET_DAYS+'&session='+encodeURIComponent(sid))
      .then(function(res){ DET_REQ[sid] = res.requests; renderDetail(); })
      .catch(function(err){ DET_REQ[sid] = []; toast('요청 목록 실패: '+err.message, true); renderDetail(); });
  }
  renderDetail();
});
el('detail').addEventListener('submit', function(e){
  if(!e.target.classList.contains('dt-plan')) return;
  e.preventDefault();
  var raw = e.target.querySelector('input').value.trim(), v = raw==='' ? null : +raw;
  if(v!==null && !(v>0 && v<=10000)){ toast('구독료는 1-10000 사이 숫자', true); return; }
  var l = DET_LABEL;
  document.activeElement.blur();
  api('/api/settings', {plan_usd: {label: l, usd: v}})
    .then(function(){ toast(l+' 월 구독료 '+(v===null ? '해제' : '$'+v)); return loadDetail(); })
    .catch(function(err){ toast('구독료 저장 실패: '+err.message, true); });
});
// 카드 빈 곳(버튼·메뉴·폼 제외)을 누르면 상세로
el('cards').addEventListener('click', function(e){
  var t = e.target;
  if(t.closest('button, a, details, form, input, label, select')) return;
  var card = t.closest('article.acct[data-l]'); if(!card) return;
  location.hash = '#/account/'+card.getAttribute('data-l');
});
window.addEventListener('hashchange', detRoute);
window.addEventListener('resize', function(){ if(DET && DET_LABEL) detChart(); });

// ── 기동 ──────────────────────────────────────────────────────────
var w0 = false;
try { w0 = sessionStorage.getItem('cct-write')==='1'; } catch(_){}
if(/[?&]write=1/.test(location.search)) w0 = true;
if(w0){ el('chk-write').checked = true; document.body.classList.add('write'); }
load().then(provAutoRefresh).catch(function(){});
detRoute();
loadHist(); loadTok();
setInterval(function(){ if(!busy) load(true).catch(function(){}); }, 30e3);
setInterval(provAutoRefresh, 600e3);                                 // 프로바이더 10분 주기 - 소비 0
setInterval(function(){ if(S){ renderTop(); renderActiveBar(); renderAlerts(); renderTokMeta(); if(!menuOpen()) renderCards(); renderTimeline(); } }, 60e3);
setInterval(loadHist, 300e3);                                        // 히스토리 5분 주기 - 로컬 sqlite 읽기만
setInterval(function(){ if(!(TOK && TOK.scanning)) loadTok(); }, 600e3);   // 토큰 10분 주기
})();
