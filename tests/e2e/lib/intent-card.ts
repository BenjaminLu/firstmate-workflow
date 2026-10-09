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

export function sceneWalkCard(mode: 'both' | 'scene' | 'walk' | 'stale' = 'both') {
  const card: any = changePointCard();
  const head = 'a'.repeat(40);
  card.expected_head = head;
  for (const locale of ['en', 'zh-TW']) {
    const en = locale === 'en';
    card.details[locale].done=[{kind:'fact',text:en ? 'Intent 1: The path keeps the records.' : '意圖 1：路徑保留記錄。'},{kind:'fact',text:en ? 'Intent 2: The path shows the records.' : '意圖 2：路徑顯示記錄。'}];
    card.details[locale].before_nodes=[{state:'same',label:en ? 'Input' : '輸入'}];
    card.details[locale].after_nodes=[{state:'same',label:en ? 'Input' : '輸入'}];
    if (mode !== 'walk') card.details[locale].scene = {
      lanes: [{label: en ? 'Records' : '記錄'}, {label: en ? 'Output' : '輸出'}],
      nodes: [
        {id:'input',label:en ? 'Input' : '輸入',lane:0,kind:'input',state:'same'},
        {id:'old',label:en ? 'Old path' : '舊路徑',lane:1,kind:'step',state:'gone',change:'c1'},
        {id:'saved',label:en ? 'Saved path' : '已存路徑',lane:1,kind:'store',state:'new',change:'c1'},
      ],
      edges: [{id:'old-path',from:'input',to:'old',state:'gone',change:'c1'}, {id:'saved-path',from:'input',to:'saved',state:'new',change:'c1'}],
      tokens: {before:['old-path'],after:['saved-path']},
      counter:{label:en ? 'Count' : '數量',before:'0',after:'1'},
      changes:[{id:'c1',text:en ? 'The path saves the input.' : '路徑儲存輸入。',intents:[1]}],
    };
  }
  if (mode !== 'scene') card.details.walk = mode === 'stale' ? {status:'stale',reviewed_head:'b'.repeat(40)} : {
    status:'valid',head,base:'c'.repeat(40),patch:'d'.repeat(64),
    intents:[{intent:1,key:[0,1].map(i=>({hunk:`src/a.py#R${i+1}-${i+1}`,kind:'code',file:'src/a.py',side:'R',start:i+1,end:i+1,
      url:`https://github.com/owner/repo/pull/9242/files#diff-abcR${i+1}`,
      rows:[{type:'del',old:i+1,new:null,text:'old()'},{type:'add',old:null,new:i+1,text:'<script>bad()</script>'}],
      note:{en:'The path keeps <b>input</b>.','zh-TW':'路徑保留輸入。'},
      line_note:{line:i+1,en:'The input stays.','zh-TW':'輸入保留。'},
      ...(mode !== 'walk' ? {changes:['c1'],step:{nodes:['saved'],edges:['saved-path']}} : {}),
    }))}],other:[{file:'other.py',hunks:3},{file:'image.bin',hunks:1,kinds:['binary']}],
  };
  return card;
}
