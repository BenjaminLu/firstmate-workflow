// The board, in a browser. Poses are asserted as classes and text as
// dictionary values, never as screenshots: a snapshot test of a ship that
// moves would fail on the animation and pass on the wrong crew.
import { expect, type Page } from "@playwright/test";
// `test` is the fixture's: every board a test starts is signed in to (T-122)
import { test, makeRoot, startBoard, stopBoard, writeRegistry, writeProjects, readTasks, writeTasks, ROOT, details, scriptHeaders, signInAddress, tabToken } from "./lib/fixture";
import { appendFileSync, readFileSync, existsSync, writeFileSync, rmSync, utimesSync, mkdirSync, chmodSync, unlinkSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { EN, TW, CN, T040_KEYS, T057_KEYS, CN_ACTIVITY, CN_DETAILS, CREW, emitFixture, emit, CN_T058, useBoard } from "./lib/board";
async function fakeAudio(page:Page, local = true, refused = false) {
  await page.addInitScript(({local,refused}) => {
    const w = window as any;
    w.sounds = {tones:[],booms:0,spoken:[],cancel:0,pause:0,stopped:0,master:1};
    const param = {setValueAtTime(){},exponentialRampToValueAtTime(){}};
    const node = () => ({connect(){return this;}, start(){},stop(){w.sounds.stopped++;},frequency:param,gain:param});
    w.AudioContext = class {
      currentTime = 0; sampleRate = 8000; state = 'suspended'; destination = {};
      resume(){return refused ? Promise.reject(new Error('autoplay refused')) : Promise.resolve();}
      createGain(){const n = node(); n.gain = {...param,setValueAtTime(v:number){w.sounds.master = v;}};return n;}
      createOscillator(){const n = node(); n.frequency = {...param,setValueAtTime(v:number){w.sounds.tones.push(v);}};return n;}
      createBuffer(){return {getChannelData:()=>new Float32Array(4000)};}
      createBufferSource(){w.sounds.booms++; return node();}
      createBiquadFilter(){return node();}
    };
    w.SpeechSynthesisUtterance = class {text:string;constructor(text:string){this.text=text;}};
    const synth = {speaking:false,pending:false,
      getVoices:()=>[{name:'remote',lang:'en-US',localService:false}, ...(local ? [{name:'local',lang:'en-US',localService:true}] : [])],
      speak(u:any){w.sounds.spoken.push({text:u.text,local:u.voice.localService}); synth.speaking=true;w.utterance=u;},
      cancel(){w.sounds.cancel++;synth.speaking=false;w.utterance?.onend?.();},
      pause(){w.sounds.pause++;},resume(){},
    };
    Object.defineProperty(w,'speechSynthesis',{value:synth});
    w.finishVoice = () => {synth.speaking=false;w.utterance?.onend?.();};
  }, {local,refused});
}
test('Ahoy speech cues stay off while merge cannon, dedupe and mute remain', async ({page}) => {
  test.setTimeout(60_000);
  await fakeAudio(page);
  const b = await startBoard(makeRoot(['working']));
  const external:string[]=[];
  page.on('request',r => {if (!r.url().startsWith(b.url)) external.push(r.url());});
  try {
    await page.goto(`${b.url}/?lang=zh-TW`);
    await page.locator('[data-c="B"]').click();
    expect(await page.evaluate(()=>(window as any).sounds.tones)).toEqual([]);
    expect(await page.evaluate(()=>(window as any).sounds.spoken)).toEqual([]);
    await page.locator('.confirm').click();
    const sound = await page.evaluate(()=>(window as any).sounds);
    expect(sound.tones).toEqual([]);expect(sound.spoken).toEqual([]);expect(sound.booms).toBe(0);
    emit(b.root,'merged',885);
    await expect(page.locator('.scene')).toHaveAttribute('data-effect','merge:885',{timeout:15_000});
    expect((await page.evaluate(()=>(window as any).sounds)).booms).toBeGreaterThan(0);
    expect((await page.evaluate(()=>(window as any).sounds)).tones).toEqual([]);
    expect((await page.evaluate(()=>(window as any).sounds)).spoken).toEqual([]);
    const before = await page.evaluate(()=>(window as any).sounds.booms);
    emit(b.root,'merged',885);
    await page.locator('#muteBtn').click();
    expect(await page.evaluate(()=>localStorage.getItem('board.muted'))).toBe('1');
    expect((await page.evaluate(()=>(window as any).sounds)).cancel).toBe(0);
    emit(b.root,'merged',886);
    await expect(page.locator('.scene')).toHaveAttribute('data-effect','merge:886',{timeout:15_000});
    expect((await page.evaluate(()=>(window as any).sounds)).booms).toBe(before);
    expect((await page.evaluate(()=>(window as any).sounds)).spoken).toEqual([]);
    expect(external).toEqual([]);
    await page.reload(); await expect(page.locator('#muteBtn')).toHaveAttribute('aria-pressed','true');
  } finally {stopBoard(b);}
});

test('audio unavailability never adds fallback noise or hides visible acknowledgement', async ({page}) => {
  await fakeAudio(page,false,true);
  const b = await startBoard(makeRoot(['working']));
  try {
    await page.emulateMedia({reducedMotion:'reduce'});
    await page.goto(`${b.url}/?lang=en`);
    await page.locator('[data-c="C"]').click(); await page.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText('AYE, CAPTAIN!');
    await expect(page.locator('#orderFeedback')).not.toContainText('Local speech unavailable');
    expect((await page.evaluate(()=>(window as any).sounds)).spoken).toEqual([]);
    expect((await page.evaluate(()=>(window as any).sounds)).tones).toEqual([]);
  } finally {stopBoard(b);}
});

test('Ahoy override never touches an unrelated browser speech queue', async ({page}) => {
  await fakeAudio(page);
  const b = await startBoard(makeRoot(['working']));
  try {
    await page.goto(`${b.url}/?lang=en`);
    await page.evaluate(()=>{(window.speechSynthesis as any).speaking=true;});
    await page.locator('[data-c="C"]').click(); await page.locator('.confirm').click();
    await expect(page.locator('#orderFeedback')).toContainText('AYE, CAPTAIN!');
    expect((await page.evaluate(()=>(window as any).sounds)).spoken).toEqual([]);
    await page.evaluate(()=>{(window.speechSynthesis as any).pending=true;});
    await page.locator('#muteBtn').click();
    const sounds = await page.evaluate(()=>(window as any).sounds);
    expect(sounds.spoken).toEqual([]);expect(sounds.cancel).toBe(0);expect(sounds.pause).toBe(0);
  } finally {stopBoard(b);}
});

