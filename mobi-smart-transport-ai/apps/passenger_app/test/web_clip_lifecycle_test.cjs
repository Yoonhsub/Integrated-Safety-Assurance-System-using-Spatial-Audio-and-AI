const {test}=require('node:test');
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
function setup(){
 const fetches=[],decodes=[],sources=[];
 class AudioContext{
  state='running';currentTime=0;destination={};
  createGain(){return {gain:{value:1,setTargetAtTime(){}},connect(){}};}
  createBufferSource(){const s={connect(){},start(){s.started=true;},stop(){s.stopped=true;}};sources.push(s);return s;}
  decodeAudioData(data,ok){decodes.push(ok);}
 }
 const window={AudioContext};
 const fetch=()=>new Promise(resolve=>fetches.push(()=>resolve({arrayBuffer:()=>Promise.resolve({})})));
 vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../web/mobi_spatial_cue.js'),'utf8'),{window,document:{addEventListener(){}},fetch,Promise,Number,Math});
 const flush=async()=>{for(let i=0;i<6;i++)await Promise.resolve();};
 return {audio:window.MobiSpatialCue,fetches,decodes,sources,flush};
}
test('cancelled clip fetch and decode never start old audio',async()=>{
 const h=setup();const old=h.audio.playClip('old',0,1);
 h.audio.stopClip();assert.equal(await old,false);
 h.fetches[0]();await h.flush();h.decodes[0]({});
 assert.equal(h.sources.length,0);
});
test('old decode cannot replace new clip; valid new clip finishes naturally',async()=>{
 const h=setup();const old=h.audio.playClip('old',0,1);
 h.fetches[0]();await h.flush();
 const next=h.audio.playClip('new',0,1);assert.equal(await old,false);
 h.decodes[0]({});assert.equal(h.sources.length,0);
 h.fetches[1]();await h.flush();h.decodes[1]({});
 assert.equal(h.sources.length,1);assert.equal(h.sources[0].started,true);
 h.sources[0].onended();assert.equal(await next,true);
});
test('clip stop failure is propagated and source retained until confirmed retry',async()=>{
 const h=setup();const playing=h.audio.playClip('clip',0,1);
 h.fetches[0]();await h.flush();h.decodes[0]({});
 let calls=0;
 h.sources[0].stop=()=>{calls++;throw new Error('uncertain');};
 assert.throws(()=>h.audio.stopClip(),/uncertain/);assert.equal(await playing,false);
 assert.throws(()=>h.audio.stopClip(),/uncertain/);
 h.sources[0].stop=()=>{calls++;};
 h.audio.stopClip();assert.equal(calls,3);
});
