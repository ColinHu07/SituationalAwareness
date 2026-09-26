import { createServer } from '../server/index.mjs';
import { once } from 'node:events';
import { writeFile } from 'node:fs/promises';
import { Session } from '../shared/protocol.mjs';
const server=createServer({env:{MODEL_MODE:'mock'}});server.listen(0,'127.0.0.1');await once(server,'listening');
const base=`http://127.0.0.1:${server.address().port}`;
const cases=[
  ['Can you have that ready by Friday?',true],
  ['I’m working on a robotics project.',true],
  ['Anyway, let’s discuss dinner.',false],
  ['The train leaves at eight.',false],
  ['[unclear speech]',false],
];
let failures=0,falseCues=0,missedCues=0;const times=[],sizes=[];
try{
  for(let i=0;i<30;i++){
    const [text,expected]=cases[i%cases.length],now=Date.now();
    const payload=JSON.stringify({transcript:[{text,startMs:now-3000,endMs:now-1600,confidence:text.includes('unclear')?0.2:0.95}],frame:null,context:[],manual:false});
    const begin=performance.now();const response=await fetch(`${base}/api/cue`,{method:'POST',headers:{'Content-Type':'application/json'},body:payload});
    const data=await response.json();times.push(performance.now()-begin);sizes.push(Buffer.byteLength(payload));
    if(!response.ok){failures++;continue;}if(data.result.should_display&&!expected)falseCues++;if(!data.result.should_display&&expected)missedCues++;
  }
  let now=Date.now(),resolve;const session=new Session({now:()=>now});session.start(true);session.append(cases[0][0],{startMs:now-3000,endMs:now-1600,confidence:0.95});
  const inFlight=session.suggest(()=>new Promise(r=>resolve=r));session.append(cases[2][0]);
  resolve({result:{cue:'Ask what they meant by Friday.',reason:'SIMULATED delayed response',confidence:0.95,type:'clarify',should_display:true}});await inFlight;
  times.sort((a,b)=>a-b);const pct=p=>Number(times[Math.floor((times.length-1)*p)].toFixed(2));
  const result={date:new Date().toISOString(),mode:'SIMULATED provider; localhost HTTP only; no glasses/model/ASR',requests:times.length,failures,p50HttpMs:pct(.5),p95HttpMs:pct(.95),minPayloadBytes:Math.min(...sizes),maxPayloadBytes:Math.max(...sizes),fixtureFalseCues:falseCues,fixtureMissedCues:missedCues,staleResponseBlocked:session.cue===null&&session.metrics.stale===1,hardwareLatencyMs:null,liveModelCostUsd:null,humanRatedDistraction:null};
  await writeFile(new URL('../docs/benchmark.json',import.meta.url),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result,null,2));
  if(failures||falseCues||missedCues||!result.staleResponseBlocked)process.exitCode=1;
}finally{server.closeAllConnections();await new Promise(r=>server.close(r));}
