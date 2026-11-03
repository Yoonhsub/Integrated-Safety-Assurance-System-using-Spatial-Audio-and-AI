// Invoke with the path produced by dart compile js test/web_live_adapter_harness.dart.
const assert=require('node:assert/strict');
const compiled=process.argv[2];
if(!compiled) throw new Error('compiled Dart harness path is required');
globalThis.self=globalThis;
globalThis.window=globalThis;
let feeds=0,passes=0,settled=false;
const sockets=[];
class Socket {
  constructor(){sockets.push(this);}
  send(text){assert.ok(text.includes('text'));}
  close(){}
}
globalThis.WebSocket=Socket;
globalThis.MobiLiveAudio={
  prepare(){},start(){},feedPcmBase64(){feeds++;},
  finish(){return Promise.resolve(true);},stop(){}
};
globalThis.adapterProbe=command=>{
  const s=sockets.at(-1);
  if(command==='noSocket')assert.equal(sockets.length,0);
  if(command==='lateSocketEvents'){
    s.onopen({});s.onmessage({data:'{"type":"audio","data":"AAAA"}'});s.onerror({});s.onclose({});
  }
  if(command==='audio')s.onmessage({data:'{"type":"audio","data":"AAAA"}'});
  if(command==='noPcm')assert.equal(feeds,0);
  if(command==='onePcm')assert.equal(feeds,1);
  if(command==='openAudioDone'){
    s.onopen({});s.onmessage({data:'{"type":"audio","data":"AAAA"}'});
    s.onmessage({data:'{"type":"done"}'});
  }
  if(command==='pass')passes++;
  if(command==='success'){settled=true;clearTimeout(deadline);console.log('Dart production Web adapter: '+passes+' PASS (browser doubles)');}
  if(command.startsWith('failure:')){settled=true;clearTimeout(deadline);console.error(command);process.exitCode=1;}
};
const deadline=setTimeout(()=>{if(!settled){console.error('adapter harness timeout');process.exit(1);}},5000);
require(require('node:path').resolve(compiled));
