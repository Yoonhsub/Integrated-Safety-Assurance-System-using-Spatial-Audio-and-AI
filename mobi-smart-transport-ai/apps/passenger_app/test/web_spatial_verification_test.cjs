const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs'),vm=require('vm'),path=require('path');
function setup(options={}) {
 const sources=[],panners=[],gains=[];let starts=0;
 const param=()=>({value:0,setValueAtTime(){},linearRampToValueAtTime(){}});
 class Node {constructor(){this.connections=[];}connect(n){this.connections.push(n);}disconnect(){this.connections=[];}}
 const ctx={state:'suspended',sampleRate:100,currentTime:0,destination:{},listener:Object.fromEntries(['positionX','positionY','positionZ','forwardX','forwardY','forwardZ','upX','upY','upZ'].map(k=>[k,param()])),
 resume(){this.state='running';return Promise.resolve();},
 suspend(){if(options.suspendPending)return new Promise(()=>{});if(options.suspendFailure)return Promise.reject(new Error('suspend failed'));this.state='suspended';return Promise.resolve();},
 close(){this.state='closed';return Promise.resolve();},
 createBuffer(_ch,length){return{getChannelData:()=>new Float32Array(length)};},
 createBufferSource(){const s=Object.assign(new Node(),{start(){starts++;},stop(){if(this.onended)this.onended();}});sources.push(s);return s;},
 createGain(){const g=Object.assign(new Node(),{gain:param()});gains.push(g);return g;},
 createStereoPanner(){const n=Object.assign(new Node(),{pan:param()});panners.push(n);return n;},
 createPanner(){const n=Object.assign(new Node(),{positionX:param(),positionY:param(),positionZ:param()});panners.push(n);return n;}};
 const window={MOBI_SPATIAL_VERIFICATION:options.enabled!==false,location:{hostname:options.remote?'remote.test':'127.0.0.1'},navigator:{userActivation:{isActive:options.gesture!==false}},
 MobiSpatialCue:{verificationContext:()=>options.unsupported?null:ctx},speechSynthesis:{speaking:false,pending:false},addEventListener(){}};
 vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../web/mobi_spatial_verification.js'),'utf8'),{window,Promise,Error,Date,Float32Array,Object,Math});
 return{api:window.MobiSpatialVerification,window,ctx,sources,panners,gains,get starts(){return starts;}};
}
for(const mode of ['STEREO','HRTF'])for(const direction of ['LEFT','CENTER','RIGHT'])test(`${mode} ${direction} uses real graph parameters and a fresh one-shot source`,async()=>{
 const f=setup();await f.api.prepare();const p=f.api.play(mode,direction);
 assert.equal(f.starts,1);assert.equal(f.sources[0].connections[0],f.gains[0]);assert.equal(f.gains[0].connections[0],f.panners[0]);
 const x={LEFT:-1,CENTER:0,RIGHT:1}[direction];
 if(mode==='STEREO')assert.equal(f.panners[0].pan.value,x);
 else{assert.equal(f.panners[0].panningModel,'HRTF');assert.equal(f.panners[0].positionX.value,x);assert.equal(f.panners[0].positionZ.value,-1);assert.equal(f.ctx.listener.forwardZ.value,-1);}
 f.sources[0].onended();assert.equal(await p,true);assert.equal(f.sources[0].connections.length,0);
 const next=f.api.play(mode,direction);assert.notEqual(f.sources[0],f.sources[1]);await f.api.stop();assert.equal(await next,false);
});
test('stop disconnects and suspends even without end callback; old callback cannot change next run',async()=>{
 const f=setup();await f.api.prepare();const p=f.api.play('STEREO','LEFT'),oldEnd=f.sources[0].onended;
 await f.api.stop();assert.equal(await p,false);assert.equal(f.ctx.state,'suspended');assert.equal(f.gains[0].connections.length,0);
 await f.api.prepare();const next=f.api.play('HRTF','RIGHT');const id=JSON.parse(f.api.snapshot()).runId;oldEnd();assert.equal(JSON.parse(f.api.snapshot()).runId,id);assert.equal(JSON.parse(f.api.snapshot()).active,true);
 await f.api.stop();await next;
});
test('TTS overlap, invalid direction and unprepared output are refused',async()=>{
 const f=setup();assert.throws(()=>f.api.play('STEREO','CENTER'));await f.api.prepare();
 f.window.speechSynthesis.speaking=true;assert.throws(()=>f.api.play('STEREO','CENTER'));f.window.speechSynthesis.speaking=false;
 assert.throws(()=>f.api.play('HRTF','BACK'));assert.throws(()=>f.api.play('UNKNOWN','LEFT'));assert.equal(f.starts,0);
 const p=f.api.play('STEREO','LEFT');assert.throws(()=>f.api.play('STEREO','RIGHT'));await f.api.stop();await p;
});
test('stop failure blocks reuse and dispose still closes context',async()=>{
 const f=setup({suspendFailure:true});await f.api.prepare();f.api.play('STEREO','LEFT');await assert.rejects(f.api.stop());
 assert.throws(()=>f.api.play('STEREO','RIGHT'));assert.equal(f.starts,1);await f.api.dispose();assert.equal(f.ctx.state,'closed');assert.equal(f.gains[0].connections.length,0);
});
test('no startup sound, no activation bypass, unsupported browser fails closed',async()=>{
 const f=setup({gesture:false});assert.equal(f.starts,0);await assert.rejects(f.api.prepare());
 await assert.rejects(setup({unsupported:true}).api.prepare());assert.equal(setup({enabled:false}).api,undefined);assert.equal(setup({remote:true}).api,undefined);
});
test('dispose retires current output and prevents new playback',async()=>{
 const f=setup();await f.api.prepare();const p=f.api.play('HRTF','CENTER');await f.api.dispose();assert.equal(await p,false);assert.equal(f.ctx.state,'closed');assert.throws(()=>f.api.play('STEREO','LEFT'));
});

test('dispose closes even when suspend never completes',async()=>{
 const f=setup({suspendPending:true});await f.api.prepare();const p=f.api.play('STEREO','LEFT');
 void f.api.stop();await Promise.resolve();await f.api.dispose();assert.equal(f.ctx.state,'closed');assert.equal(await p,false);assert.throws(()=>f.api.play('STEREO','RIGHT'));
});
test('graph creation error cannot leave a connected or playable source',async()=>{
 const f=setup();await f.api.prepare();f.ctx.createPanner=()=>{throw new Error('unsupported HRTF');};
 await assert.rejects(f.api.play('HRTF','LEFT'));assert.equal(f.starts,0);await f.api.dispose();
});

test('short directional cue reuses HRTF graph with a 600ms local buffer',async()=>{
 const f=setup();await f.api.prepare();const p=f.api.playCue('LEFT');
 const event=JSON.parse(f.api.snapshot()).events.find(e=>e.kind==='graph_connected');
 assert.equal(event.mode,'HRTF');assert.equal(event.direction,'LEFT');assert.equal(event.durationMs,600);
 assert.equal(f.panners[0].panningModel,'HRTF');await f.api.stop();assert.equal(await p,false);assert.equal(f.sources[0].connections.length,0);
});
