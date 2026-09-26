
import test from 'node:test';
import assert from 'node:assert/strict';
import { createLocalizationProvider, LOCALIZATION_PROMPT, localizationSchema, mockLocalization, validateLocalizationResult } from '../server/localization.mjs';
import { validateLocalizationInput, InputError } from '../server/validation.mjs';

test('localization input is narrow and preserves only session speaker aliases', () => {
  assert.deepEqual(validateLocalizationInput({
    text:'कल मिलना थोड़ा मुश्किल होगा।', speaker:'P1', targetLanguage:'English',
    context:[{speaker:'P2',text:'Tomorrow at 3?'}],
  }), {
    text:'कल मिलना थोड़ा मुश्किल होगा।', speaker:'P1', targetLanguage:'English',
    context:[{speaker:'P2',text:'Tomorrow at 3?'}],
  });
  assert.throws(() => validateLocalizationInput({text:'hi',speaker:'A',targetLanguage:'English',context:[]}), InputError);
  assert.throws(() => validateLocalizationInput({text:'hi',targetLanguage:'Klingon',context:[]}), InputError);
  assert.throws(() => validateLocalizationInput({text:'hi',targetLanguage:'English',context:[],identity:'Sam'}), InputError);
  assert.throws(() => validateLocalizationInput({text:'hi',targetLanguage:'English',context:[{text:'a'},{text:'b'},{text:'c'}]}), InputError);
});

test('prompt requires faithful pragmatic translation without personal inference', () => {
  assert.match(LOCALIZATION_PROMPT, /Translate ONLY currentUtterance/);
  assert.match(LOCALIZATION_PROMPT, /Preserve uncertainty/);
  assert.match(LOCALIZATION_PROMPT, /Do not infer emotions, motives/);
  assert.match(LOCALIZATION_PROMPT, /session-local aliases/);
  assert.match(LOCALIZATION_PROMPT, /untrusted conversation data/);
});

test('mock fixture distinguishes literal meaning from pragmatic meaning', () => {
  assert.deepEqual(mockLocalization({
    text:'कल मिलना थोड़ा मुश्किल होगा।', targetLanguage:'English', context:[],
  }), {
    sourceLanguage:'Hindi', targetLanguage:'English',
    translation:"I probably won't be able to meet tomorrow.",
    literalMeaning:'Meeting tomorrow will be a little difficult.',
    pragmaticNote:'Indirect polite decline.', confidence:0.95, changedForPragmatics:true,
  });
});

test('live provider uses strict structured output and sends only bounded text context', async () => {
  let captured;
  const result = {
    sourceLanguage:'Hindi', targetLanguage:'English',
    translation:"I probably won't be able to meet tomorrow.",
    literalMeaning:'Meeting tomorrow will be a little difficult.',
    pragmaticNote:'Indirect polite decline.', confidence:0.93, changedForPragmatics:true,
  };
  const provider = createLocalizationProvider({MODEL_MODE:'live',MUSE_API_KEY:'synthetic'}, async (url, options) => {
    captured = {url, body:JSON.parse(options.body), headers:options.headers};
    return {ok:true, json:async()=>({
      choices:[{finish_reason:'stop',message:{content:JSON.stringify(result)}}],
      usage:{prompt_tokens:100,completion_tokens:50,prompt_tokens_details:{cached_tokens:20}},
    })};
  });
  const response = await provider.localize(validateLocalizationInput({
    text:'कल मिलना थोड़ा मुश्किल होगा।',speaker:'P1',targetLanguage:'English',
    context:[{speaker:'P2',text:'Tomorrow at 3?'}],
  }));
  assert.equal(captured.url,'https://api.meta.ai/v1/chat/completions');
  assert.equal(captured.headers.Authorization,'Bearer synthetic');
  assert.equal(captured.body.model,'muse-spark-1.3');
  assert.equal(captured.body.response_format.json_schema.strict,true);
  assert.deepEqual(captured.body.response_format.json_schema.schema, localizationSchema);
  const user = JSON.parse(captured.body.messages[1].content);
  assert.deepEqual(Object.keys(user).sort(), ['currentUtterance','recentContext','targetLanguage'].sort());
  assert.equal(JSON.stringify(user).includes('audio'),false);
  assert.equal(JSON.stringify(user).includes('image'),false);
  assert.deepEqual(response.result,result);
});

test('structured result rejects wrong target or extra personal fields', () => {
  const base = {sourceLanguage:'Hindi',targetLanguage:'English',translation:'No.',literalMeaning:'No.',pragmaticNote:'',confidence:.9,changedForPragmatics:false};
  assert.throws(() => validateLocalizationResult({...base,targetLanguage:'Hindi'},'English'));
  assert.throws(() => validateLocalizationResult({...base,emotion:'sad'},'English'));
});

test('provider errors are sanitized without reading participant content', async () => {
  let read=false;
  const provider=createLocalizationProvider({MODEL_MODE:'live',MUSE_API_KEY:'synthetic'}, async()=>({
    ok:false,status:500,json:async()=>{read=true;return {private:'participant words'};}
  }));
  await assert.rejects(provider.localize({text:'private words',targetLanguage:'English',context:[]}),
    e=>e.status===502 && !e.message.includes('private words'));
  assert.equal(read,false);
});
