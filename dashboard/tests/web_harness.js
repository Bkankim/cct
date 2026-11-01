'use strict';
// app.js 렌더 함수 테스트용 하네스 - 브라우저 없이 node vm 에서 app.js 를 불러온다.
// DOM·저장소·타이머는 무엇을 호출해도 조용히 받아 주는 스텁이다.
// 사용: node web_harness.js <app.js> <state.json>  ->  stdout 에 {label: 카드 HTML} JSON
const fs = require('fs');
const vm = require('vm');

function stub(){
  const fn = function(){ return p; };
  const p = new Proxy(fn, {
    get(_, k){
      if(k === Symbol.toPrimitive) return () => '';
      if(k === 'then') return undefined;   // Promise 로 오인되지 않게
      return p;
    },
    set(){ return true; },
    apply(){ return p; },
    construct(){ return p; },
  });
  return p;
}

const [appPath, statePath] = process.argv.slice(2);
const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
const s = stub();
const ctx = {
  document: s, location: {search: '', hash: ''}, sessionStorage: s, localStorage: s,
  navigator: s, matchMedia: s, requestAnimationFrame: s, getComputedStyle: s,
  fetch: () => new Promise(() => {}),
  setInterval: () => 0, setTimeout: () => 0, clearInterval: () => {}, clearTimeout: () => {},
  console, Math, Date, JSON, Promise, Intl,
};
ctx.window = ctx;
ctx.addEventListener = () => {};
ctx.__cctTest = {};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(appPath, 'utf8'), ctx, {filename: 'app.js'});

const T = ctx.__cctTest;
const v = T.toView(state);
// renderCards 의 dupMap 과 같은 규칙(org|7d_reset)으로 중복 맵을 만든다
const dups = {};
v.accounts.forEach(a => {
  const k = (a.org && a.w7 && a.w7.r) ? a.org + '|' + a.w7.r : null;
  if(k) (dups[k] = dups[k] || []).push(a.label);
});
const out = {};
v.accounts.forEach(a => { out[a.label] = T.accountCard(a, dups, null); });
process.stdout.write(JSON.stringify(out));
