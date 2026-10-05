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

