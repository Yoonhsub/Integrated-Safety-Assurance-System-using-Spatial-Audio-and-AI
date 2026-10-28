// Local verification graph on the existing SpatialCue AudioContext. No fetching.
(() => {
  'use strict';
  if (window.MOBI_SPATIAL_VERIFICATION !== true ||
      !['127.0.0.1', 'localhost'].includes(window.location.hostname)) return;
  let ctx = null, active = null, stopping = null, preparing = null;
  let disposed = false, blocked = false, sequence = 0, revision = 0;
  let phase = 'idle'; const events = [];
  const positions = {LEFT:[-1,0,-1],CENTER:[0,0,-1],RIGHT:[1,0,-1]};
  function mark(kind, extra = {}) {
    events.push({kind, at:Date.now(), runId:sequence, ...extra});
    if (events.length > 64) events.shift();
  }
  function ready() {
    if (disposed || blocked) throw new Error('Spatial output unavailable; reload required');
  }
  function disconnect(run) {
    // Disconnect the output first, even when the source's stop callback is lost.
    run.gain.disconnect(); run.source.disconnect(); run.panner.disconnect();
  }
  function finish(run, natural) {
    if (run.done) return;
    run.done = true;
    if (active === run) active = null;
    disconnect(run);
    phase = natural ? 'completed' : 'stopped';
    mark(natural ? 'completed' : 'cancelled', {completedRun:run.id});
    run.resolve(natural);
  }
  function prepare() {
    ready();
    if (!window.navigator.userActivation?.isActive) return Promise.reject(new Error('User gesture required'));
    if (stopping) return Promise.reject(new Error('Shutdown in flight'));
    if (preparing) return preparing;
    const ticket = revision;
    ctx = window.MobiSpatialCue?.verificationContext();
    if (!ctx) return Promise.reject(new Error('Web Audio unsupported'));
    preparing = Promise.resolve(ctx.resume()).then(() => {
      ready();
      if (ticket !== revision || ctx.state !== 'running') throw new Error('Audio activation retired');
      mark('prepared');
    }).finally(() => { preparing = null; });
    return preparing;
  }
  function play(mode, direction) {
    ready();
    if (!['STEREO','HRTF'].includes(mode) || !Object.hasOwn(positions,direction)) throw new Error('Unreviewed direction');
    if (stopping || active || !ctx || ctx.state !== 'running') throw new Error('Output busy or unprepared');
    if (window.speechSynthesis?.speaking || window.speechSynthesis?.pending) throw new Error('TTS overlap refused');
    return new Promise((resolve, reject) => {
      let run;
      try {
        const source = ctx.createBufferSource(), gain = ctx.createGain();
        const panner = mode === 'STEREO' ? ctx.createStereoPanner() : ctx.createPanner();
        run = {source,gain,panner,resolve,id:++sequence,done:false};
        active = run; phase = 'requested';
        const buffer = ctx.createBuffer(1, Math.round(ctx.sampleRate * 4), ctx.sampleRate);
        const data = buffer.getChannelData(0); let seed = 502;
        for (let i=0; i<data.length; i++) {
          seed = (1664525 * seed + 1013904223) >>> 0;
          data[i] = 0.3*Math.sin(2*Math.PI*440*i/ctx.sampleRate) +
            0.2*Math.sin(2*Math.PI*880*i/ctx.sampleRate) + 0.25*(seed/4294967296*2-1);
        }
        source.buffer = buffer;
        gain.gain.setValueAtTime(0, ctx.currentTime);
        gain.gain.linearRampToValueAtTime(0.12, ctx.currentTime + 0.03);
        gain.gain.setValueAtTime(0.12, ctx.currentTime + 3.95);
        gain.gain.linearRampToValueAtTime(0, ctx.currentTime + 4);
        const pan = direction === 'LEFT' ? -1 : direction === 'RIGHT' ? 1 : 0;
        if (mode === 'STEREO') panner.pan.value = pan;
        else {
          panner.panningModel = 'HRTF'; panner.distanceModel = 'inverse';
          panner.refDistance = 1; panner.rolloffFactor = 0; // Test direction only, no real distance inference.
          const pos = positions[direction];
          panner.positionX.value=pos[0];panner.positionY.value=pos[1];panner.positionZ.value=pos[2];
          const l=ctx.listener;
          l.positionX.value=0;l.positionY.value=0;l.positionZ.value=0;
          l.forwardX.value=0;l.forwardY.value=0;l.forwardZ.value=-1;
          l.upX.value=0;l.upY.value=1;l.upZ.value=0;
        }
        source.connect(gain);gain.connect(panner);panner.connect(ctx.destination);
        source.onended=()=>{if(!run.done)finish(run,true);};
        mark('graph_connected',{mode,direction,pan,position:mode==='HRTF'?positions[direction]:null});
        source.start();phase='playing';mark('started',{mode,direction});
      } catch(error) {
        if(run) { try {disconnect(run);} catch(_){} run.done=true; active=null; }
        phase='failed';mark('error');reject(error);
      }
    });
  }
  function stop() {
    if(stopping)return stopping;
    revision++;const run=active;phase='stopping';mark('stop_requested');
    stopping=Promise.resolve().then(async()=>{
      if(run&&!run.done){disconnect(run);run.source.onended=null;run.source.stop();}
      if(preparing) {try{await preparing;}catch(_){}}
      if(ctx&&ctx.state!=='closed')await ctx.suspend();
      if(ctx&&!['suspended','closed'].includes(ctx.state))throw new Error('Unconfirmed suspension');
      if(run&&!run.done)finish(run,false);
      phase='stopped';mark('stop_confirmed');return true;
    }).catch(error=>{blocked=true;phase='blocked';mark('stop_failed');throw error;})
      .finally(()=>{stopping=null;});
    return stopping;
  }
  async function dispose() {
    if(disposed)return;
    disposed=true;revision++;const run=active;
    // Closing must not wait behind an indefinitely pending suspend/stop.
    if(run&&!run.done){try{disconnect(run);run.source.onended=null;run.source.stop();}catch(_){blocked=true;}}
    if(ctx&&ctx.state!=='closed')await ctx.close();
    if(ctx&&ctx.state!=='closed'){blocked=true;phase='blocked';throw new Error('Context close unconfirmed');}
    if(run&&!run.done)finish(run,false);
    phase='disposed';mark('disposed');
  }
  function snapshot(){return JSON.stringify({phase,contextState:ctx?.state||'not_created',
    active:!!active,blocked,disposed,runId:sequence,events:[...events],
    coordinates:'listener origin; forward -Z; right +X; up +Y; arbitrary test units',
    source:'LOCAL_GENERATED_MONO_TEST_BUFFER',ttsSpatialized:false});}
  window.MobiSpatialVerification={prepare,play,stop,dispose,snapshot};
  window.addEventListener('pagehide',()=>{void dispose().catch(()=>{});});
})();
