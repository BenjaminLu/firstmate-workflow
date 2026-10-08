import { expect, type Page } from "@playwright/test";
// `test` is the fixture's: every board a test starts is signed in to (T-122)
import { test, makeRoot, startBoard, stopBoard, writeRegistry, writeProjects, readTasks, writeTasks, ROOT, details, scriptHeaders, signInAddress, tabToken } from "./fixture";
import { appendFileSync, readFileSync, existsSync, writeFileSync, rmSync, utimesSync, mkdirSync, chmodSync, unlinkSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
export const EN = JSON.parse(readFileSync(join(ROOT, "i18n/ui.en.json"), "utf8"));
export const TW = JSON.parse(readFileSync(join(ROOT, "i18n/ui.zh-TW.json"), "utf8"));
// Independently authored oracles: using the production conversion table here
// made an incorrect or incomplete table prove itself correct.
export const CN = {merged:'已合并',inflight:'进行中',blocked:'受阻',aboard:'在船上',
  roster:'船员名册',descriptionUnavailable:'尚无工作说明',waitingOnYou:'等你拍板',
  titleMissing:'任务文件未列出标题',blockedOn:'卡在',gateFailedN:'第 {n} 道闸（{label}）未过',
  optionsN:'{n} 个选项',rosterBtn:'名册',crossVendor:'跨供应商审核',mergedMore:'另 {n} 个在已完成历史中',
  alsoWaiting:'其他待决（点开就地展开）',
  engine:'引擎',gateFailed:'闸门未过',viewDesign:'design.md',
  laneWorking:'施工',laneGate:'闸门',laneReview:'审核',capDeciding:'在后甲板上裁决',
  ready:'就绪',backlog:'待办',laneReady:'就绪',laneBacklog:'待办'};
// Every key T-040 added. Each must have an oracle above, and the board's own
// conversion must reproduce it: an oracle only some keys are checked against
// let 閘門未過 ship half-converted.
export const T040_KEYS = ['engine','crossVendor','waitingOnYou','blockedOn','titleMissing','mergedMore',
  'gateFailed','gateFailedN','optionsN','rosterBtn','alsoWaiting','viewDesign'];
// and every key T-057 added, held to the same rule
export const T057_KEYS = ['ready','backlog','laneReady','laneBacklog'];
export const CN_ACTIVITY = {
  build:'Rowan 实作船长决策', test:'Rowan 测试决策', literal:'验证船长原文命令',
  bea:'Bea 审查船长决策',
};
export const CN_DETAILS = [
  {title:'缓存任务索引',explanation:'每次重新整理只读取一次索引。',before:'每张卡片重读任务文件',after:'每次重新整理共用一份索引',outcome:'已记录索引选择',options:{
    A:{description:'每次重新整理建立缓存',pros:'减少读取',cons:'占用内存'},
    B:{description:'保留各自读取',pros:'无需缓存',cons:'重复读取'},
    C:{description:'先测量',pros:'取得证据再变更',cons:'延后改善'}}},
  {title:'限制审查重试',explanation:'三次后停止',before:'无限重试',after:'最多三次',outcome:'已记录重试策略',options:{
    A:{description:'限制重试',pros:'可预测代价',cons:'需要手动恢复'},
    B:{description:'保留各自读取',pros:'无需缓存',cons:'重复读取'},
    C:{description:'先测量',pros:'取得证据再变更',cons:'延后改善'}}},
];
export const CREW = ["working", "gate", "review", "working", "gate"] as const;

export function emitFixture(root:string, actor:string, task:string, type:string, en='', tw='', data={}) {
  const args=[join(root,'bin/fm-emit.sh'),'--actor',actor,'--task',task,'--type',type,'--data',JSON.stringify(data)];
  if(en)args.push('--en',en,'--tw',tw);
  const result=spawnSync('bash',args,{env:{...process.env,FM_ROOT:root,FM_EMIT_LEGACY_GATE: typeof (data as {gate?:unknown}).gate === "number" ? "1" : ""}});
  expect(result.status,result.stderr.toString()).toBe(0);
}

export const CN_T058 = {park:'搁置',unpark:'恢复',drop:'不做',parked:'已搁置',dropped:'已不做',
  cardActions:'{id} 的操作',dropZone:'拖曳卡片到此：不做',dropConfirm:'确定不做 {id}？此任务将离开各列，不再做；design/tasks/ 不变。',
  dropYes:'确定不做',cancel:'取消',actionFailed:'看板未能记录此操作，请重新整理后再试。'};

export function useBoard() {
  const board = {} as Awaited<ReturnType<typeof startBoard>>;
  test.beforeAll(async () => { Object.assign(board, await startBoard(makeRoot([...CREW]))); });
  test.afterAll(() => stopBoard(board));
// one mechanism at a time. Setting both meant neither was covered: the
// query parameter could have stopped working and the suite would have
// stayed green on the stored value.
const open = async (page: Page, lang: string, how: "query" | "stored" = "query", url = board.url) => {
  if (how === "query") {
    await page.goto(`${url}/?lang=${lang}`);
    await page.evaluate(() => localStorage.removeItem("board.lang"));
    await page.reload();
  } else {
    await page.goto(url);
    await page.evaluate((l) => localStorage.setItem("board.lang", l), lang);
    await page.goto(url);                 // no query parameter this time
  }
  await expect(page.locator("#rosterBtn")).not.toHaveText("");
  await expect(page.locator("#roster .rrow").first()).toBeAttached();
};
  return { board, open };
}

export const emit = (root:string, type:string, pr:number) => {
  const r = spawnSync('bash',[join(root,'bin/fm-emit.sh'),'--actor','github','--type',type,'--task',`T-${pr}`,'--pr',String(pr),'--en','fixture outcome','--tw','測試結果'], {env:{...process.env,FM_ROOT:root}});
  expect(r.status).toBe(0);
};

// Navigate through the same controls as the captain; sheets never stack.
export async function showFleet(page: Page) {
  await expect(page.locator("#tabFleet")).not.toHaveText("");
  const sheet = page.locator('.board-sheet[open]');
  if (await sheet.count()) await sheet.locator('[data-sheet-close]').click();
  await page.locator('#tabFleet').click();
}
export async function openCrewSheet(page: Page) {
  await expect(page.locator("#rosterBtn")).not.toHaveText("");
  const log = page.locator('#logSheet[open]');
  if (await log.count()) await log.locator('[data-sheet-close]').click();
  if (!await page.locator('#crewSheet').isVisible()) await page.locator('#rosterBtn').click();
}
export async function openLogSheet(page: Page) {
  await expect(page.locator("#logBtn")).not.toHaveText("");
  const crew = page.locator('#crewSheet[open]');
  if (await crew.count()) await crew.locator('[data-sheet-close]').click();
  if (!await page.locator('#logSheet').isVisible()) await page.locator('#logBtn').click();
}
