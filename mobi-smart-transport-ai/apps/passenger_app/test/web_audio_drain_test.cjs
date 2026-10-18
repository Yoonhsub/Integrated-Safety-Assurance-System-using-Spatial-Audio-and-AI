// Executes the production audio-buffer implementation with a deterministic
// AudioContext, without claiming real speaker or browser permission coverage.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const production = process.argv[2] || path.join(__dirname, '../web/mobi_live_audio.js');
function setup() {
  const sources = [];
  class AudioContext {
    currentTime = 0; state = 'running'; destination = {};
    createAnalyser() { return {connect(){}, getFloatTimeDomainData(){}, fftSize:512}; }
    createBuffer(channels, length, rate) { return {duration:length/rate, copyToChannel(){}}; }
    createBufferSource() {
      const source = {connect(){}, start(){}, stop(){}, addEventListener(name, cb){this.end=cb;}};
      sources.push(source); return source;
    }
  }
  const window = {AudioContext, atob:s=>Buffer.from(s,'base64').toString('binary')};
  vm.runInNewContext(fs.readFileSync(production, 'utf8'), {window, Float32Array, Set, Promise});
  return {audio:window.MobiLiveAudio, sources};
}
test('finish waits for every scheduled buffer, not network done', async()=>{
  const {audio,sources}=setup(); audio.start(24000);
  audio.feedPcmBase64('AAAAAA=='); audio.feedPcmBase64('AAAAAA==');
  let ended=false; const drain=audio.finish().then(n=>{ended=true;return n;});
  await Promise.resolve(); assert.equal(ended,false);
  sources[0].end(); await Promise.resolve(); assert.equal(ended,false);
  sources[1].end(); assert.equal(await drain,true);
});
test('stop resolves drain as cancellation and late prior end cannot drain new run',async()=>{
  const {audio,sources}=setup(); audio.start(24000); audio.feedPcmBase64('AAAAAA==');
  const retired=audio.finish(); audio.stop(); assert.equal(await retired,false);
  audio.start(24000); audio.feedPcmBase64('AAAAAA==');
  let ended=false; const next=audio.finish().then(n=>{ended=true;return n;});
  sources[0].end(); await Promise.resolve(); assert.equal(ended,false);
  sources[1].end(); assert.equal(await next,true);
});
test('empty playback drains, stop and finish are repeatable',async()=>{
  const {audio}=setup(); audio.start(24000);
  assert.equal(await audio.finish(),true); audio.stop(); audio.stop();
  assert.equal(await audio.finish(),true);
});

test('stop failure remains observable, attempts other sources, and permits confirmed retry',async()=>{
  const {audio,sources}=setup(); audio.start(24000);
  audio.feedPcmBase64('AAAAAA=='); audio.feedPcmBase64('AAAAAA==');
  let secondStopped=0;
  sources[0].stop=()=>{throw new Error('output uncertain');};
  sources[1].stop=()=>{secondStopped++;};
  const drain=audio.finish();
  assert.throws(()=>audio.stop(),/output uncertain/);
  assert.equal(await drain,false);
  assert.equal(secondStopped,1);
  // A failed stop must not allow start() to silently reuse active output.
  assert.throws(()=>audio.start(24000),/output uncertain/);
  sources[0].stop=()=>{};
  audio.stop();
  assert.equal(await audio.finish(),true);
  audio.start(24000);
});
