import { details } from './fixture';
// Stored reports deliberately differ from the prose's word count: the page must
// display the report, not implement a second STE checker.
export function intentCard(id = 'D-211') {
  const content: any = structuredClone(details);
  for (const lang of ['en', 'zh-TW']) Object.assign(content[lang], {
    intent: [{kind:'step',text:lang === 'en' ? 'Show the change <script>bad()</script>.' : '檢查任務修改。'}],
    why: [{kind:'fact',text:lang === 'en' ? 'The captain sees the scope.' : '船長看見範圍。'}],
    scope_in: ['Board cards'], scope_out: ['Other pages'],
    done: [{kind:'fact',text:'The card shows the result.'}],
    notes: [{kind:'note',text:'Check the scope.'},{kind:'caution',text:'Do not dispatch yet.'}],
    questions: [{kind:'fact',text:'The scope is correct.'},{kind:'fact',text:'The result is correct.'}],
  });
  const entry = (field:string, index:number, issues:any[] = []) => ({field,index,sentence:'Stored sentence',kind:'step',n:17,max:20,issues});
  const card = {id,kind:'choice',task:'T-211',details:content,ste:{intent_card:true,ok:false,labels:{en:[], 'zh-TW':[]},locales:{
    en:[entry('intent',0,[{rule:'R3',severity:'fail',detail:'two steps'}]),entry('why',0),entry('done',0),entry('notes',0,[{rule:'R7',severity:'warn',detail:'review'}]),entry('questions',0),entry('questions',1)],
    'zh-TW':[entry('intent',0,[{rule:'Z2',severity:'fail',detail:'two actions'}]),entry('questions',0),entry('questions',1)],
  }}};
  for (const lang of ['en','zh-TW'] as const) for (const entry of card.ste.locales[lang])
    entry.sentence = content[lang][entry.field][entry.index].text;
  content.en.why[0].text += ' The card stays small.';
  card.ste.locales.en.push({...entry('why',0),sentence:'The card stays small.',n:4});
  return card;
}


// Explicit opt-in: legacy cards and selected-copy defaults remain unchanged.
export function changePointCard(kind: 'one-way' | 'two-way' = 'one-way', id = 'D-9242') {
  const card: any = intentCard(id);
  card.kind = 'merge'; card.pr = 9242; card.check_answer = 0;
  for (const locale of ['en', 'zh-TW']) {
    const en = locale === 'en';
    const content = card.details[locale];
    delete content.questions;
    content.intent = [{kind:'fact',text:en ? 'Keep the saved records.' : '保留已存記錄。'}, {kind:'fact',text:en ? 'Show the records.' : '顯示記錄。'}];
    content.change_points = [{intent:1,how:en ? 'Keep the saved records.' : '保留已存記錄。'}, {intent:2,how:en ? 'Show the records.' : '顯示記錄。'}];
    content.door = {kind,reason:en ? 'Published records cannot be recalled.' : '已發布記錄無法收回。',rollback:en ? 'Keep the saved records.' : '保留已存記錄。'};
    if (kind === 'one-way') content.check = {q:en ? 'What must stay?' : '必須留下什麼？',options:en ? ['Keep the saved records.','Lose records.'] : ['保留已存記錄。','刪除記錄。'],why:en ? 'Keep the saved records.' : '保留已存記錄。',about:{intent:1}};
    else delete content.check;
  }
  if (kind === 'two-way') delete card.check_answer;
  card.details.refs = {spec_url:'https://github.com/owner/repo/blob/' + 'a'.repeat(40) + '/design/tasks/T-211.json',acceptance:['Keep the saved records.','Show the records.'],points:[0,1].map(i=>({acceptance:[i],code:[{file:'src/a.py',start:i+1,end:i+1,url:'https://github.com/owner/repo/pull/9242/files#diff-abcR'+(i+1),snippet:'saved_records()'}],tests:[{file:'tests/a.py',line:i+1,name:'test_saved_'+i,url:'https://github.com/owner/repo/blob/'+'a'.repeat(40)+'/tests/a.py#L'+(i+1)}]}))};
  return card;
}
