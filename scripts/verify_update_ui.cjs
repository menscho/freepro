const fs=require('fs'),vm=require('vm'),assert=require('assert');
const {parseHTML}=require('../.verify/ui-tests/node_modules/linkedom');
const {window}=parseHTML(fs.readFileSync('src/web/index.html','utf8'));const document=window.document;
let status={current:'0.1.0',available:false,phase:'checking'},polls=[],posts=0,reloaded=false;
window.location={reload(){reloaded=true;}};
const sandbox={window,document,console,Promise,setTimeout(fn,ms){if(ms===1000)polls.push(fn);return 0;},clearTimeout(){},fetch:async(path,init)=>{
 let data=path.includes('quick-adds')?{token:'test-token'}:status;
 if(init?.method==='POST'){assert.equal(JSON.parse(init.body).token,'test-token');posts++;}
 return {ok:true,status:200,json:async()=>data,text:async()=>JSON.stringify(data)};
}};
let source=fs.readFileSync('src/web/app.js','utf8').replace('  if (document.readyState === "loading") {','  globalThis.testing = {initUpdates};\n  if (false) {').replace('    init();\n  }\n})();','  }\n})();');
vm.runInNewContext(source,sandbox);const tick=()=>new Promise(r=>setImmediate(r));
(async()=>{
 sandbox.testing.initUpdates();await tick();assert(document.getElementById('update-area').hidden);assert.equal(polls.length,1);
 status={current:'0.1.0',available:true,version:'v0.2.0',phase:'available'};
 polls.shift()();await tick();assert(!document.getElementById('update-area').hidden);
 status.phase='downloading';document.getElementById('app-update').click();await tick();assert.equal(posts,1);assert(document.getElementById('app-update').disabled);assert(polls.length);
 status={current:'0.2.0',available:false,phase:'idle'};polls.shift()();await tick();assert(reloaded);
 console.log('PASS update button hidden without a release, shown with a release, authenticated install request, progress and post-restart reload');
})().catch(e=>{console.error(e);process.exitCode=1;});
