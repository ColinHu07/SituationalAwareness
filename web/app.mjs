import { Session, LIMITS } from '/shared/protocol.mjs';
const $ = id => document.getElementById(id);
let health, deviceMode = 'simulated', cameraStream, micStream, audioContext, recordingGeneration = 0;
let networkDown = false, lastRequestRevision = -1, lastSample = 0, distracting = 0, demoTimers = [];
let captureGeneration = 0, lastVideoTime = -1, asrController, micBusy = false;
const session = new Session({ onChange: render });
const simLabel = () => deviceMode === 'simulated';
function render() {
  const running = session.state === 'running';
  $('state').textContent = session.state.toUpperCase(); $('state-dot').classList.toggle('active', running);
  $('start').disabled = running; $('start').querySelector('span').textContent = session.state === 'paused' ? 'Resume session' : 'Start session';
  for (const id of ['pause','help','test-cue','camera','microphone']) $(id).disabled = !running;
  $('microphone').disabled = !running || micBusy;
  $('stop').disabled = session.state === 'stopped'; $('dismiss').disabled = !session.cue;
  $('input-mode').disabled = session.state !== 'stopped'; $('context').disabled = session.state !== 'stopped';
  $('consent').disabled = running;
  $('cue').textContent = session.cue?.cue ?? (session.state === 'paused' ? 'A little breathing room.' : running ? 'Here when you need a cue.' : 'Your conversation comes first.');
  $('cue-icon').textContent = session.cue ? '↗' : '◌';
  $('cue-detail').textContent = session.cue ? `${session.cue.type.replace('_',' ')} · disappears in ${Math.max(0,Math.ceil((session.cue.expiresAtMs-Date.now())/1000))}s` : 'Simulated display · hardware not connected';
  $('status').textContent = session.lastReason;
  const lastSpeech = session.transcript.at(-1);
  $('caption-label').textContent = simLabel() ? 'SIMULATED CAPTIONS' : 'CAPTIONS / EXPLICIT TEXT INPUT';
  $('caption-text').textContent = lastSpeech && Date.now()-lastSpeech.endMs <= LIMITS.speechMs && (lastSpeech.confidence == null || lastSpeech.confidence >= 0.65) ? lastSpeech.text : 'Speech will appear here.';
  $('saved-note').textContent = session.context[0] || 'Add an optional note in Session setup.';
  $('transcript').replaceChildren();
  if (!session.transcript.length) { const p = document.createElement('p'); p.className = 'empty'; p.textContent = 'Nothing captured. You’re in control.'; $('transcript').append(p); }
  for (const item of session.transcript) {
    const row = document.createElement('p'); row.className='utterance';
    const time=document.createElement('time'); time.textContent=new Date(item.endMs).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit',second:'2-digit'});
    const text=document.createElement('span'); text.textContent=item.text; row.append(time,text); $('transcript').append(row);
  }
  $('transcript').scrollTop=$('transcript').scrollHeight;
  $('transcript-count').textContent=`${session.transcript.length} utterances`;
  $('metric-cues').textContent=session.metrics.displayed;
  const api=session.metrics.apiMs.at(-1); $('metric-api').textContent=api == null ? '—' : `${Math.round(api)} ms`;
  $('metric-stale').textContent=session.metrics.stale;
  $('metric-bytes').textContent=`${(session.metrics.uploadBytes/1024).toFixed(1)} KB`;
  $('metric-cost').textContent=session.metrics.costUnknown ? 'Incomplete usage' : `$${session.metrics.costUsd.toFixed(4)}`;
  $('metric-asr').textContent=session.metrics.transcriptionMs.length ? `${Math.round(session.metrics.transcriptionMs.at(-1))} ms` : '—';
  $('disconnect').textContent=session.connected?'Disconnect device':'Reconnect device';
}
function status(message) { session.lastReason = message; render(); }
async function request(path, payload, signal) {
  if (networkDown) throw new Error('Simulated network unavailable');
  const response=await fetch(path, { method:'POST', headers:{'Content-Type':'application/json', ...($('proxy-token').value ? {Authorization:`Bearer ${$('proxy-token').value}`} : {})}, body:JSON.stringify(payload), signal });
  if (!response.ok) throw new Error((await response.json()).error);
  return response.json();
}
async function model(payload, signal) {
  if(simLabel() && health?.modelMode === 'live') throw new Error('Use mock backend for scripted demo; use browser input for live model.');
  if(!simLabel() && health?.modelMode !== 'live') throw new Error('Live input requires live backend; no silent simulated response.');
  return request('/api/cue',payload,signal);
}
function stopInputs() {
  captureGeneration++; recordingGeneration++;
  asrController?.abort(); asrController = null;
  micBusy = false;
  cameraStream?.getTracks().forEach(t=>t.stop());cameraStream=null;$('preview').srcObject=null;
  micStream?.getTracks().forEach(t=>t.stop());micStream=null;
  audioContext?.close();audioContext=null;$('microphone').textContent='Record browser mic · 6 sec';
  demoTimers.forEach(clearTimeout);demoTimers=[];
}
function pause() { stopInputs();session.pause(); }
function stop() { stopInputs();session.stop();$('utterance').value='';$('context').value='';$('consent').checked=false; }
$('start').onclick=()=>{try{session.start($('consent').checked);session.context=$('context').value.trim()?[$('context').value.trim()]:[];}catch(e){status(e.message);}};
$('pause').onclick=pause;$('stop').onclick=stop;$('dismiss').onclick=()=>session.dismiss();
$('help').onclick=()=>{if(!session.ready(true))return status('Wait for a quiet moment with recent speech.');session.suggest(model,true);};
$('test-cue').onclick=()=>{session.invalidate('Manually triggered simulated display cue.');session.cue={cue:'A little help. You’re still in charge.',type:'manual test',expiresAtMs:Date.now()+8000};render();};
$('input-mode').onchange=()=>{deviceMode=$('input-mode').value;$('simulation-controls').hidden=!simLabel();$('browser-controls').hidden=simLabel();$('manual-label').textContent=simLabel()?'simulated input':'explicit text fallback';$('input-description').textContent=simLabel()?'Scripted text and a simulated display. No glasses or microphone are connected.':'Actual browser camera and optional microphone. Glasses capture and display are only in the native iOS app.';$('privacy').textContent=simLabel()?'In simulation, inputs stay in this local prototype. Stop clears session content.':'Live mode sends selected images, audio chunks and transcript to Meta through your backend. Standard API data is not used for training, but provider retention applies.';$('consent').checked=false;};
function say(text, confidence = null) { if(session.state!=='running')return status('Start a consented session first.');session.append(text,{confidence}); }
document.querySelectorAll('[data-say]').forEach(button=>button.onclick=()=>say(button.dataset.say,Number(button.dataset.confidence??0.95)));
$('utterance-form').onsubmit=e=>{e.preventDefault();say($('utterance').value);$('utterance').value='';};
$('utterance').oninput=()=>{if(session.state==='running'){session.speechStart();}};
$('demo').onclick=()=>{if(session.state!=='running')return status('Start a consented session first.');demoTimers.forEach(clearTimeout);say('Can you have that ready by Friday?',0.95);demoTimers=[setTimeout(()=>say('Actually, let’s talk about dinner instead.',0.98),5500),setTimeout(()=>status('Script finished. The new subject cleared the old cue.'),8000)];};
$('disconnect').onclick=()=>{if(session.connected){stopInputs();session.disconnect();}else{session.reconnect();status('Reconnected. Resume only when you are ready.');}};
$('network').onclick=()=>{networkDown=!networkDown;$('network').textContent=networkDown?'Restore network':'Simulate network loss';session.invalidate(networkDown?'Simulated network loss. Cues cleared.':'Network restored. Waiting for fresh context.');};
$('distracting').onclick=()=>{if(!session.cue)return status('Mark feedback while a cue is visible.');distracting++;$('feedback').textContent=`${distracting} distracting cues marked. Feedback is local and anonymous.`;session.dismiss();};
$('export').onclick=()=>{const blob=new Blob([JSON.stringify({mode:health?.modelMode,deviceMode,hardwareTested:false,distracting,...session.metrics},null,2)],{type:'application/json'});const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='aside-metrics.json';a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000);};
$('camera').onclick=async()=>{const generation=captureGeneration;try{const stream=await navigator.mediaDevices.getUserMedia({video:{width:640,height:480,frameRate:5},audio:false});if(generation!==captureGeneration||session.state!=='running'){stream.getTracks().forEach(t=>t.stop());return;}cameraStream?.getTracks().forEach(t=>t.stop());cameraStream=stream;lastVideoTime=-1;$('preview').srcObject=stream;stream.getVideoTracks()[0].addEventListener('ended',()=>{if(cameraStream===stream){pause();status('Camera disconnected. Session paused.');}});status('Browser camera active. Sampling at most one frame every 5 seconds.');}catch{status('Camera permission denied or unavailable. No camera input.');}};

function wav(samples, rate) {
  const count=Math.floor(samples.length*16000/rate), bytes=new ArrayBuffer(44+count*2), view=new DataView(bytes);
  const str=(at,s)=>[...s].forEach((c,i)=>view.setUint8(at+i,c.charCodeAt(0)));
  str(0,'RIFF');view.setUint32(4,36+count*2,true);str(8,'WAVE');str(12,'fmt ');view.setUint32(16,16,true);view.setUint16(20,1,true);view.setUint16(22,1,true);view.setUint32(24,16000,true);view.setUint32(28,32000,true);view.setUint16(32,2,true);view.setUint16(34,16,true);str(36,'data');view.setUint32(40,count*2,true);
  for(let i=0;i<count;i++){const a=Math.floor(i*rate/16000),b=Math.max(a+1,Math.floor((i+1)*rate/16000));let s=0;for(let j=a;j<b&&j<samples.length;j++)s+=samples[j];view.setInt16(44+i*2,Math.max(-1,Math.min(1,s/(b-a)))*32767,true);}
  let binary='';for(const b of new Uint8Array(bytes))binary+=String.fromCharCode(b);return btoa(binary);
}
$('microphone').onclick=async()=>{
  if(health?.modelMode!=='live')return status('Real microphone transcription needs MODEL_MODE=live and a server-side API key.');
  if(micBusy)return;
  micBusy=true;
  const generation=++recordingGeneration;let context,stream,node,source,zero;
  try{
    stream=await navigator.mediaDevices.getUserMedia({audio:{channelCount:1},video:false});
    if(generation!==recordingGeneration||session.state!=='running'){stream.getTracks().forEach(t=>t.stop());return;}
    micStream=stream;context=new AudioContext();audioContext=context;source=context.createMediaStreamSource(stream);
    // Development-only browser fallback. Native app uses AVAudioEngine, not this deprecated browser node.
    node=context.createScriptProcessor(4096,1,1);zero=context.createGain();zero.gain.value=0;source.connect(node);node.connect(zero);zero.connect(context.destination);
    const chunks=[],startedAtMs=Date.now();session.speechStart();$('microphone').textContent='Recording browser mic…';
    node.onaudioprocess=e=>{if(generation===recordingGeneration&&chunks.length<150)chunks.push(new Float32Array(e.inputBuffer.getChannelData(0)));};
    await new Promise(resolve=>setTimeout(resolve,6000));node.disconnect();source.disconnect();zero.disconnect();stream.getTracks().forEach(t=>t.stop());
    const sampleRate=context.sampleRate;await context.close();if(audioContext===context)audioContext=null;
    if(generation!==recordingGeneration||session.state!=='running')return;
    const endedAtMs=Date.now(),samples=new Float32Array(chunks.reduce((s,x)=>s+x.length,0));let p=0;for(const c of chunks){samples.set(c,p);p+=c.length;}
    $('microphone').textContent='Transcribing…';const revision=session.revision;
    asrController=new AbortController();
    const audioPayload={audioBase64:wav(samples,sampleRate),mimeType:'audio/wav',sampleRate:16000,startedAtMs,endedAtMs};
    session.metrics.uploadBytes+=new TextEncoder().encode(JSON.stringify(audioPayload)).length;
    const result=await request('/api/transcribe',audioPayload,AbortSignal.any([AbortSignal.timeout(10000),asrController.signal]));
    if(generation!==recordingGeneration||session.state!=='running'||revision!==session.revision)return;
    session.speaking=false;session.metrics.costUsd+=result.estimatedCostUsd??0;
    if(result.estimatedCostUsd==null)session.metrics.costUnknown=true;
    session.metrics.transcriptionMs.push(result.transcriptionMs);session.metrics.transcriptionMs=session.metrics.transcriptionMs.slice(-100);
    if(result.text.trim())session.append(result.text,{startMs:startedAtMs,endMs:endedAtMs,confidence:null});else{pause();status('No clear speech transcribed. Paused and cleared prior context.');}
  }catch{if(generation===recordingGeneration){pause();status('Microphone or transcription unavailable. Paused; no speech was substituted.');}}
  finally{stream?.getTracks().forEach(t=>t.stop());if(context&&context.state!=='closed')await context.close();if(audioContext===context)audioContext=null;if(generation===recordingGeneration){micBusy=false;asrController=null;}$('microphone').textContent='Record browser mic · 6 sec';}
};
document.addEventListener('keydown',e=>{if(e.key==='Escape'){e.preventDefault();stop();return;}if(['INPUT','TEXTAREA','SELECT'].includes(e.target.tagName))return;if(e.code==='Space'){e.preventDefault();pause();}else if(e.key==='Enter'&&e.target.tagName!=='BUTTON'){session.dismiss();}});
document.addEventListener('visibilitychange',()=>{if(document.hidden&&session.state==='running')pause();});
window.addEventListener('pagehide',stop);
setInterval(()=>{
  session.tick();
  if(cameraStream&&session.state==='running'&&Date.now()-lastSample>=LIMITS.sampleMs&&$('preview').videoWidth&&$('preview').currentTime!==lastVideoTime){
    lastVideoTime=$('preview').currentTime;
    const canvas=document.createElement('canvas');canvas.width=640;canvas.height=Math.round(640*$('preview').videoHeight/$('preview').videoWidth);canvas.getContext('2d').drawImage($('preview'),0,0,canvas.width,canvas.height);session.setFrame({dataUrl:canvas.toDataURL('image/jpeg',0.65),capturedAtMs:Date.now()});lastSample=Date.now();
  }
  if(session.ready()&&lastRequestRevision!==session.revision){lastRequestRevision=session.revision;session.suggest(model);}
  render();
},500);
try{health=await(await fetch('/api/health')).json();$('provider').textContent=health.modelMode==='mock'?'SIMULATED MODEL':'LIVE · MUSE SPARK';$('token-label').hidden=!health.requiresToken;$('proxy-token').hidden=!health.requiresToken;if(health.modelMode==='live'){$('metric-note').textContent='API usage is measured; browser display timing is not glasses latency.';}}catch{status('Backend unavailable. Start it with npm start.');$('provider').textContent='OFFLINE';}
render();
