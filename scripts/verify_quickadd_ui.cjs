const fs=require('fs'),vm=require('vm'),assert=require('assert');
const {parseHTML}=require('../.verify/ui-tests/node_modules/linkedom');
const {window}=parseHTML(fs.readFileSync('src/web/index.html','utf8'));
const document=window.document;window.location={hash:''};
let response={path:'C:\\Users\\Test\\.kimi-code\\config.toml',token:'fixture'},ok=true,calls=[];
const sandbox={document,window,console,Promise,setTimeout(){return 0;},clearTimeout(){},fetch:async(path,init)=>{calls.push({path,init});return {ok,json:async()=>response};}};
const source=fs.readFileSync('src/web/app.js','utf8').replace('  if (document.readyState === "loading") {','  globalThis.testing = {showView, applyQuickAdd};\n  if (false) {').replace('    init();\n  }\n})();','  }\n})();');
vm.runInNewContext(source,sandbox);
const flush=()=>new Promise(r=>setImmediate(r));
(async()=>{
const t=sandbox.testing,button=document.getElementById('kimi-add-update'),status=document.getElementById('kimi-add-status');
assert(!document.getElementById('proxy-pill'));assert(!document.querySelector('.rail-bottom'));
t.showView('quick-adds');await flush();assert(!document.getElementById('view-quick-adds').hidden);assert.equal(button.disabled,false);assert(document.getElementById('kimi-config-path').textContent.includes('.kimi-code'));
response={changed:true,added:2,updated:1};t.applyQuickAdd();t.applyQuickAdd();assert(button.disabled);await flush();assert.equal(calls.filter(c=>c.init?.method==='POST').length,1);assert(status.textContent.includes('2 added, 1 updated'));assert(status.textContent.includes('/reload'));assert.equal(button.disabled,false);
response={changed:false,added:0,updated:0};t.applyQuickAdd();await flush();assert(status.textContent.includes('Already up to date'));
ok=false;response={error:{message:'Enable at least one model first.'}};t.applyQuickAdd();await flush();assert.equal(status.dataset.error,'true');assert(status.textContent.includes('Enable at least one model'));assert.equal(button.disabled,false);
console.log('PASS Quick adds navigation, config path, add/update, double-click guard, no-change and error states');
})().catch(e=>{console.error(e);process.exitCode=1;});
