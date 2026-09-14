'use strict';
// cct 대시보드 프론트 - /api/state 를 폴링해 렌더하고, 버튼은 실제 엔드포인트를 호출한다.
// 표시 로직(추천 계정·중복 판정·게이지)은 클라이언트, 사실은 서버가 내려준다.
(function(){
var M = 60e3, H = 3600e3, D = 86400e3;
var RESERVED = ['help','ls','list','add','run','rm','rename','status','doctor','check','fp','who','usage','off','active','refresh','use'];
var S = null;          // 뷰모델
var RAW = null;        // 마지막 /api/state 원본
var busy = false;

function el(id){ return document.getElementById(id); }
function esc(s){ return String(s).replace(/[&<>"]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
function pad(n){ return (n<10?'0':'')+n; }
function ms(sec){ return (sec===null||sec===undefined) ? null : sec*1000; }
function clock(ts, withDate){ var d=new Date(ts); var t=pad(d.getHours())+':'+pad(d.getMinutes()); return withDate ? pad(d.getMonth()+1)+'-'+pad(d.getDate())+' '+t : t; }
function remaining(ts){ var diff=ts-Date.now(); if(diff<=0) return '지남'; var d=Math.floor(diff/D), h=Math.floor(diff%D/H), m=Math.floor(diff%H/M); if(d>0) return d+'d'+h+'h'; if(h>0) return h+'h'+m+'m'; return m+'m'; }
function when(ts, withDate){ if(!ts) return '리셋 (-)'; var r=remaining(ts); return r==='지남' ? '리셋 지남 ('+clock(ts,withDate)+')' : '리셋 '+r+' 후 ('+clock(ts,withDate)+')'; }
function ago(ts){ if(!ts) return '-'; var s=Math.round((Date.now()-ts)/1000); if(s<60) return s+'초 전'; if(s<3600) return Math.round(s/60)+'분 전'; return Math.round(s/3600)+'시간 전'; }
function pct(u){ return (u===null||u===undefined) ? '-' : Math.round(u*100)+'%'; }
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
function toView(st){
  var v = {
    server: st.server || {},
    status: {
      wallet: (st.status&&st.status.wallet)||'-', mode:(st.status&&st.status.mode)||'-',
      accounts:(st.status&&st.status.accounts)||0, active:(st.status&&st.status.active)||'',
      def:(st.status&&st.status['default'])||'', sticky:(st.status&&st.status.sticky)||'-',
      claude:(st.status&&st.status.claude_version)||'-'
    },
    budget: st.budget || {},
    refreshing: !!st.refreshing,
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

// ── 렌더 ──────────────────────────────────────────────────────────
function gauge(k, w, cls, withDate){
  if(!w) return '';
  var p = (w.u===null||w.u===undefined) ? 0 : Math.min(100, Math.round(w.u*100));
  var hot = p>=80 || w.s==='rejected';
  var flag = (w.s && w.s!=='allowed') ? ' <span class="flag">['+k+'-status:'+esc(w.s)+']</span>' : '';
  return '<div class="gauge '+cls+'"><span class="k">'+k+'</span><div class="bar"><i class="'+(hot?'hot':'')+'" style="width:'+p+'%"></i></div><span class="pct">'+pct(w.u)+'</span></div>'
       + '<div class="sub"><span></span><span>'+when(w.r, withDate)+flag+'</span></div>';
}
function checkText(a){
  if(!a.check) return '-';
  var t = a.check.res==='valid' ? '✅ 유효' : a.check.res==='invalid' ? '❌ 무효' : '❓ 토큰 없음';
  return t + (a.check.at ? ' <span class="help">('+ago(a.check.at)+')</span>' : '');
}
function renderHeader(){
  var sv = S.server||{};
  var tag = el('tag-mode');
  tag.textContent = sv.fake ? '픽스처 모드 (fake)' : '실계정 연결';
  tag.className = 'tag ' + (sv.fake ? 'fake' : 'live');
  el('chip-server').innerHTML = '서버 <b>'+esc(sv.bind||'-')+'</b>' + (sv.version ? ' · v'+esc(sv.version) : '');
  var probed = S.accounts.filter(function(a){ return a.probeAt; }).map(function(a){ return a.probeAt; });
  var last = probed.length ? Math.max.apply(null, probed) : null;
  el('chip-last').innerHTML = '마지막 프로브 <b>'+(last ? ago(last)+' ('+clock(last,false)+')' : '없음')+'</b>';
  var b = S.budget||{}, n = S.accounts.filter(function(a){ return a.token; }).length;
  var perDay = b.auto_min ? Math.round(n * (24*60/b.auto_min)) : 0;
  el('chip-budget').innerHTML = '오늘 프로브 <b>'+((b.usage_probes||0)+(b.check_probes||0))+'회 · ≈'+(b.est_tokens||0)+' tok</b>'
    + (perDay ? '· 자동 '+b.auto_min+'분 → 하루 ≈'+perDay+'회' : '· 자동 꺼짐');
  var sel = el('sel-auto'); if(String(b.auto_min) !== sel.value) sel.value = String(b.auto_min===undefined?30:b.auto_min);
  var rb = el('btn-refresh');
  rb.disabled = !!S.refreshing;
  rb.innerHTML = S.refreshing ? '<span class="spin"></span> 갱신 중' : '전체 갱신 (usage --all)';
}
function renderStatus(){
  var st = S.status, d = S.doctor;
  var nP=0,nW=0,nF=0;
  d.forEach(function(x){ if(x.lv==='PASS')nP++; else if(x.lv==='WARN')nW++; else nF++; });
  el('status-chips').innerHTML = [
    ['wallet', st.wallet+' (mode '+st.mode+')'], ['accounts', st.accounts], ['active', st.active||'none'],
    ['default', st.def||'-'], ['sticky', st.sticky], ['claude', st.claude]
  ].map(function(p){ return '<span class="chip">'+p[0]+' <b class="mono">'+esc(p[1])+'</b></span>'; }).join('')
  + '<span class="chip '+(nF?'bad':nW?'warn':'ok')+'">doctor <b>'+nP+' PASS · '+nW+' WARN · '+nF+' FAIL</b></span>';
}
function renderRec(){
  var r = recommend(), b = el('rec');
  if(!r){ b.innerHTML = '<div><b>갈아탈 계정 없음</b><div class="help">프로브된 계정이 없거나 모두 소진·무효 상태입니다. 전체 갱신을 눌러 보세요.</div></div>'; return; }
  var det = '5h '+pct(r.w5.u)+' · 7d '+pct(r.w7.u)+(r.wf?' · 7f '+pct(r.wf.u):'')+' · 병목 '+pct(headroom(r));
  if(r.label===S.status.active){ b.innerHTML = '<div><b>현재 계정('+esc(r.label)+')이 최적</b><div class="help">'+det+' - 여유가 가장 큽니다</div></div>'; return; }
  b.innerHTML = '<div><b>지금 갈아탈 계정: <span class="mono">'+esc(r.label)+'</span></b><div class="help">'+det+' · '+when(r.w5.r,false)+'<br>정렬: 가장 빡빡한 창(5h/7d/7f) 기준 · 활성과 동일 계정(중복)·rejected 제외</div></div>'
    + '<div class="actions"><code>cct '+esc(r.label)+'</code><button data-act="copy" data-l="'+esc(r.label)+'">복사</button><button class="primary" data-act="use" data-l="'+esc(r.label)+'">활성화 (cct use)</button></div>';
}
function kv(k,v){ return '<div class="kv"><div class="k">'+k+'</div><div class="v">'+v+'</div></div>'; }
function renderLive(){
  var L = S.live;
  if(!L){ el('live').innerHTML = '<h2>활성 세션 라이브 <span class="help">statusline 캐시 없음</span></h2><div class="help">Claude Code 세션이 statusline 을 갱신하면 여기에 표시됩니다.</div>'; return; }
  var five = L.fiveH||{}, seven = L.sevenD||{};
  el('live').innerHTML = '<h2>활성 세션 라이브 <span class="help">statusline 캐시 · 프로브 0회 · '+ago(L.at)+(L.stale?' · <span class="flag">stale</span>':'')+'</span></h2>'
   + '<div class="live">'
   + kv('계정', esc(L.label||'-')+' <small>추정</small>') + kv('모델', esc(L.model))
   + kv('컨텍스트', (L.ctx===null||L.ctx===undefined?'-':L.ctx+'%')) + kv('세션 비용', '$'+(L.cost||0).toFixed(2))
   + kv('5h', (five.used_percentage===undefined?'-':five.used_percentage+'%') + (five.resets_at?' <small>'+remaining(ms(five.resets_at))+'</small>':''))
   + kv('7d', (seven.used_percentage===undefined?'-':seven.used_percentage+'%') + (seven.resets_at?' <small>'+remaining(ms(seven.resets_at))+'</small>':''))
   + '</div><div class="help" style="margin-top:8px">Claude Code 가 statusline 에 넘기는 rate_limits 를 그대로 읽습니다. 계정 라벨은 읽은 시점의 활성 라벨로 추정한 값입니다.</div>';
}
function addCard(){
  return '<div class="card add"><h3>계정 등록 <span class="badge">cct add</span></h3>'
   + '<form id="form-add"><div class="row"><input id="add-label" placeholder="라벨 (a-z0-9_)" autocomplete="off" required></div>'
   + '<div class="row"><input id="add-token" type="password" placeholder="setup-token (화면·로그 미표시)" autocomplete="off" required></div>'
   + '<div class="row"><label class="chip toggle"><input type="checkbox" id="add-ow"> 기존 라벨 덮어쓰기</label></div>'
   + '<div class="row"><button class="primary" type="submit">등록</button><span class="help">Mac 서버로만 전송(테일넷 내부). 지갑 mode 600 유지.</span></div></form></div>';
}
function renderCards(){
  var dups = dupMap(), rec = recommend();
  var html = S.accounts.map(function(a){
    var isRec = rec && rec.label===a.label && !a.isActive;
    var cls = 'card' + (a.isActive?' active':'') + (isRec?' rec':'') + ((!a.token||!a.ok)?' dead':'');
    var badges = '';
    if(a.isActive) badges += '<span class="badge active">활성</span>';
    if(a.isDefault) badges += '<span class="badge def">기본</span>';
    if(isRec) badges += '<span class="badge rec">추천</span>';
    var k = fpKey(a);
    if(k && dups[k].length>1){ var others = dups[k].filter(function(l){ return l!==a.label; }); badges += '<span class="badge warn" title="org·7d_reset 동일 = 같은 계정">중복: '+esc(others.join(', '))+'</span>'; }
    var body;
    if(!a.token) body = '<div class="dead-msg">토큰없음 (비어있음) - 쓰기 모드에서 등록하거나 터미널에서 cct add '+esc(a.label)+'</div>';
    else if(a.state==='no_response') body = '<div class="dead-msg bad">응답실패 - 토큰 무효·만료 가능성. 재발급 후 cct add '+esc(a.label)+' 로 교체</div>';
    else if(a.state==='parse_error') body = '<div class="dead-msg bad">출력 해석 실패 - 서버 로그를 확인하세요</div>';
    else if(!a.w5) body = '<div class="dead-msg">미프로브 - 갱신을 누르면 usage 프로브 실행</div>';
    else {
      body = gauge('5h', a.w5, 'w5', false) + gauge('7d', a.w7, 'w7', true);
      if(a.denied) body += '<div class="sub"><span class="k">7f</span><span class="flag">프리미엄 프로브 거부('+esc(a.denied)+') - 창 소진 가능성</span></div>';
      else if(a.wf) body += gauge('7f', a.wf, 'wf', true);
    }
    var probeTxt = a.probeAt ? ago(a.probeAt) : (a.token ? '미프로브' : '-');
    var meta = '<div class="meta"><span>프로브 <b>'+probeTxt+'</b></span>' + (a.org ? '<span>org <b class="mono">'+esc(a.org)+'</b></span>' : '') + '<span>check <b>'+checkText(a)+'</b></span></div>';
    var dis = a.token ? '' : ' disabled';
    var act = '<div class="actions">'
      + '<button data-act="usage" data-l="'+esc(a.label)+'"'+dis+'>갱신</button>'
      + '<button data-act="check" data-l="'+esc(a.label)+'"'+dis+'>점검</button>'
      + '<button data-act="copy" data-l="'+esc(a.label)+'">cct '+esc(a.label)+' 복사</button>'
      + (a.isActive ? '' : '<button data-act="use" data-l="'+esc(a.label)+'"'+dis+'>활성화</button>')
      + '<button class="write-only" data-act="rename" data-l="'+esc(a.label)+'">이름변경</button>'
      + '<button class="write-only danger" data-act="rm" data-l="'+esc(a.label)+'">삭제</button>'
      + '</div>';
    return '<div class="'+cls+'"><h3><span class="lbl">'+esc(a.label)+'</span>'+badges+'</h3>'+body+meta+act+'</div>';
  }).join('');
  el('cards').innerHTML = html + addCard();
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
      if(x>=0 && x<=1) dots += '<span class="dot '+p[2]+'" style="left:'+(x*100)+'%" title="'+esc(a.label)+' '+p[0]+' '+when(w.r,p[3])+'"></span>';
      else if(x>1 && p[0]==='7d') later.push(esc(a.label)+' 7d '+when(w.r,true));
    });
    rows += '<div class="tl-row"><span class="'+(a.isActive?'lbl-active':'')+'">'+esc(a.label)+'</span><div class="tl-track">'+dots+'</div></div>';
  });
  el('timeline').innerHTML = '<div class="tl-axis">'+axis+'</div>'+(rows || '<div class="help" style="padding:10px 0 0 64px">프로브된 계정이 없습니다.</div>');
  el('tl-legend').innerHTML = '<span><i class="dot d5"></i>5h</span><span><i class="dot d7"></i>7d</span><span><i class="dot df"></i>7f</span><span>· 24h 밖 7d 리셋: '+(later.length ? later.join(' · ') : '없음')+'</span>';
}
function renderDoctor(){ el('doctor').innerHTML = S.doctor.length ? S.doctor.map(function(x){ return '<li><span class="lv '+x.lv+'">'+x.lv+'</span><span>'+esc(x.msg)+'</span></li>'; }).join('') : '<li>doctor 결과 없음</li>'; }
function renderLog(){ el('log').innerHTML = S.log.length ? S.log.slice(0,12).map(function(x){ var d=new Date(x.at); return '<li><span class="t">'+clock(x.at,false)+':'+pad(d.getSeconds())+'</span><span class="cmd">'+esc(x.cmd)+'</span><span class="rc '+(x.rc===0?'PASS':'FAIL')+'">rc='+x.rc+'</span><span class="ms">'+x.ms+'ms</span></li>'; }).join('') : '<li>기록 없음</li>'; }
function render(){ if(!S) return; renderHeader(); renderStatus(); renderRec(); renderLive(); renderCards(); renderTimeline(); renderDoctor(); renderLog(); }

// ── 토스트·에러 ───────────────────────────────────────────────────
var tt;
function toast(m, bad){ var t=el('toast'); t.textContent=m; t.className='toast show'+(bad?' bad':''); clearTimeout(tt); tt=setTimeout(function(){ t.className='toast'; }, 3200); }
function showErr(m){ var e=el('err'); if(!m){ e.hidden=true; return; } e.hidden=false; e.textContent='서버 통신 실패: '+m; }

// ── 상태 로드 ─────────────────────────────────────────────────────
function load(){
  return api('/api/state').then(function(st){ RAW=st; S=toView(st); showErr(''); render(); return st; })
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

// ── 이벤트 ────────────────────────────────────────────────────────
document.addEventListener('click', function(e){
  var b = e.target.closest ? e.target.closest('button[data-act]') : null; if(!b) return;
  var a = b.getAttribute('data-act'), l = b.getAttribute('data-l');
  if(a==='copy'){ copy('cct '+l); return; }
  if(a==='usage') return act(b, l+' 갱신', function(){ return api('/api/refresh', {label:l}); });
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
el('btn-refresh').addEventListener('click', function(){ act(this, '전체 갱신', function(){ return api('/api/refresh', {all:true}); }); });
el('btn-off').addEventListener('click', function(){
  if(!confirm('cct off - 활성(sticky) 라벨을 해제할까요?\n라벨 없는 cct/claude 는 기본 라벨로 실행됩니다.')) return;
  act(this, '활성 해제', function(){ return api('/api/off', {}); });
});
el('sel-auto').addEventListener('change', function(){
  var v = +this.value, self = this;
  act(null, '자동갱신 설정', function(){ return api('/api/settings', {auto_min:v}); })
    .then(function(){ toast(v===0 ? '자동갱신 끔 - 수동 갱신만' : '자동갱신 '+v+'분 (하한 15분: 프로브가 사용량을 소비)'); });
});
el('chk-write').addEventListener('change', function(){
  document.body.classList.toggle('write', this.checked);
  try { sessionStorage.setItem('cct-write', this.checked ? '1':'0'); } catch(_){}
  toast(this.checked ? '쓰기 모드 켬 - 토큰 값은 화면·로그에 표시되지 않음' : '쓰기 모드 끔 (읽기 전용)');
});

// ── 기동 ──────────────────────────────────────────────────────────
var w0 = false;
try { w0 = sessionStorage.getItem('cct-write')==='1'; } catch(_){}
if(/[?&]write=1/.test(location.search)) w0 = true;
if(w0){ el('chk-write').checked = true; document.body.classList.add('write'); }
load().catch(function(){});
setInterval(function(){ if(!busy) load().catch(function(){}); }, 30e3);
setInterval(function(){ if(S){ renderHeader(); renderLive(); renderCards(); renderTimeline(); } }, 60e3);
})();
