const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
function setup() {
  const requests=[];
  const s={speaking:false,pending:false,getVoices:()=>[{lang:'ko-KR'}],
    speak(u){this.speaking=true;requests.push(u);return null;},
    cancel(){this.speaking=false;this.pending=false;}};
  const window={speechSynthesis:s,SpeechSynthesisUtterance:class{constructor(text){this.text=text;}},setTimeout};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../web/mobi_tts.js'),'utf8'),{window,Promise,Error,Date});
  return {tts:window.MobiTts,s,requests};
}
test('normal Web null request return is neither failure nor completion',async()=>{
 const {tts,s,requests}=setup();tts.prepare(true);
 let done=false;const playing=tts.speak('위험').then(v=>{done=true;return v;});
 await Promise.resolve();assert.equal(done,false);
 s.speaking=false;requests[0].onend();assert.equal(await playing,true);
});
test('stop without any platform cancellation callback permits next valid speech',async()=>{
 const {tts,s,requests}=setup();const old=tts.speak('old');
 assert.equal(await tts.stop(),true);assert.equal(await old,false);
 const next=tts.speak('new');assert.equal(requests.length,2);
 s.speaking=false;requests[1].onend();assert.equal(await next,true);
});
test('late old cancel, complete and error never retire new safety utterance',async()=>{
 const {tts,s,requests}=setup();const old=tts.speak('old');await tts.stop();await old;
 let done=false;const next=tts.speak('위험').then(v=>{done=true;return v;});
 requests[0].onerror({error:'interrupted'});requests[0].onend();requests[0].onerror({error:'network'});
 await Promise.resolve();assert.equal(done,false);assert.equal(s.speaking,true);
 s.speaking=false;requests[1].onend();assert.equal(await next,true);
});
test('engine error is failure; explicit interruption is cancellation',async()=>{
 const {tts,s,requests}=setup();const first=tts.speak('one');
 const failed=assert.rejects(first,/Speech engine failed/);s.speaking=false;
 requests[0].onerror({error:'network'});await failed;
 const second=tts.speak('two');s.speaking=false;
 requests[1].onerror({error:'canceled'});assert.equal(await second,false);
});
test('repeated stop and stale callback remain silent and do not queue audio',async()=>{
 const {tts,requests}=setup();const old=tts.speak('old');
 await tts.stop();await tts.stop();requests[0].onend();
 assert.equal(await old,false);assert.equal(requests.length,1);
});


test('prefer local Korean voice; snapshot distinguishes request/start/completion',async()=>{
 const {tts,s,requests}=setup();
 s.getVoices=()=>[{lang:'ko-KR',localService:false},{lang:'ko-KR',localService:true}];
 tts.prepare(true);const playing=tts.speak('테스트 음성 출력입니다.');
 assert.equal(requests[0].voice.localService,true);
 assert.equal(JSON.parse(tts.snapshot()).phase,'requested');
 requests[0].onstart();assert.equal(JSON.parse(tts.snapshot()).counts.starts,1);
 s.speaking=false;requests[0].onend();assert.equal(await playing,true);
 assert.equal(JSON.parse(tts.snapshot()).counts.completions,1);
 assert.equal(JSON.parse(tts.snapshot()).selectedVoiceLocal,true);
});

test('late retired start callback cannot change current engine diagnostics',async()=>{
 const {tts,s,requests}=setup();const old=tts.speak('old');await tts.stop();await old;
 const next=tts.speak('new');const id=JSON.parse(tts.snapshot()).runId;
 requests[0].onstart();requests[0].onend();
 assert.equal(JSON.parse(tts.snapshot()).runId,id);
 assert.equal(JSON.parse(tts.snapshot()).phase,'requested');
 s.speaking=false;requests[1].onend();await next;
});
