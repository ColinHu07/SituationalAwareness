import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createProvider } from '../server/model.mjs';
import { validateInput } from '../server/validation.mjs';
if(existsSync('.env'))process.loadEnvFile('.env');
const args=process.argv.slice(2),imagePath=args[args.indexOf('--image')+1];
if(!args.includes('--consented')||!args.includes('--image')||!imagePath){
  console.error('Usage: npm run smoke:live -- --image /path/to/consented-sampled-frame.jpg --consented');
  console.error('Sends the supplied actual frame to Meta; no built-in stock frame or transcript is substituted.');process.exit(2);
}
if(!process.env.MUSE_API_KEY){console.error('Set MUSE_API_KEY in the ignored .env file first.');process.exit(2);}
const bytes=await readFile(imagePath),mime=bytes[0]===0x89?'image/png':'image/jpeg';
const now=Date.now();
const payload=validateInput({transcript:[{text:'The wearer requested a connection test. There is no conversational evidence; abstain.',startMs:now,endMs:now,confidence:null}],frame:{dataUrl:`data:${mime};base64,${bytes.toString('base64')}`,capturedAtMs:now},context:[],manual:true});
const provider=createProvider({...process.env,MODEL_MODE:'live'});
try{
 const response=await provider.cue(payload);
 console.log(JSON.stringify({liveRequestSucceeded:true,structuredResultValid:true,shouldDisplay:response.result.should_display,metrics:response.metrics},null,2));
 console.log('Image and generated content are not written to disk by this script. This verifies API transport, not cue quality or glasses capture.');
}catch(error){console.error('Live smoke test failed:',error.message);process.exitCode=1;}
