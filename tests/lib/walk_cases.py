"""Scene and retained-walk behavior. New helper absence is setup, not red."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

# Isolated fixtures must not inherit the active worker's identity or stores.
for name in list(os.environ):
    if name.startswith(('FM_', 'HERDR_')):
        os.environ.pop(name)
ROOT = Path(sys.argv.pop(1))
sys.path[:0] = [str(ROOT / 'bin/lib'), str(ROOT / 'tests/lib')]
from ste_cases import card
import fm_ste
import fm_spec_preflight


def scene():
    return dict(lanes=[dict(label='Flow')], nodes=[
        dict(id='input', label='Input', lane=0, kind='input', state='same'),
        dict(id='output', label='Output', lane=0, kind='step', state='same')],
        edges=[dict(id='path', **{'from': 'input', 'to': 'output'}, state='same')],
        tokens=dict(before=['path'], after=['path']),
        changes=[dict(id='c1', text='The path carries the input.', intents=[1])])


def spec():
    fields = ('intent', 'why', 'scope_in', 'scope_out', 'done', 'notes', 'before_nodes', 'after_nodes')
    explain = {lang: {k: v for k, v in loc.items() if k in fields} for lang, loc in card().items()}
    for loc in explain.values():
        loc['scene'] = scene()
    return dict(id='T-001', title='The task works.', scope=['tests/walk.test.sh'],
                acceptance=['The path works.'], explain=explain)


class Scene(unittest.TestCase):
    def test_scene_cli_accepts(self):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / 'spec.json'
            path.write_text(json.dumps(spec()))
            result = subprocess.run([sys.executable, str(ROOT / 'bin/lib/fm_ste.py'),
                                     'check-explain', str(path)], capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)

    def test_scene_preflight_accepts(self):
        fm_spec_preflight.prompt('T-001', json.dumps(spec()).encode(), 'a' * 40)

    def test_field_errors(self):
        cases = [
            ('lane', lambda s: s['nodes'][0].update(lane=1)),
            ('id', lambda s: s['edges'][0].update(id='input')),
            ('changes', lambda s: s['changes'][0].update(id='c2')),
            ('change', lambda s: s['nodes'][0].update(state='gone')),
            ('change', lambda s: s['nodes'][0].update(change='c1')),
            ('from', lambda s: s['edges'][0].update(**{'from': 'missing'})),
            ('tokens', lambda s: s['tokens'].update(before=['path', 'path'])),
            ('intents', lambda s: s['changes'][0].update(intents=[999])),
            ('label', lambda s: s['lanes'][0].update(label='one two three four five six seven')),
            ('text', lambda s: s['changes'][0].update(text='The path works. The input moves.')),
            ('counter', lambda s: s.update(counter=dict(label='Count', before='', after='1'))),
        ]
        for field, mutate in cases:
            with self.subTest(field=field):
                value = spec()
                mutate(value['explain']['en']['scene'])
                with self.assertRaisesRegex(ValueError, field):
                    fm_ste.check_explain(value['explain'])


    def test_counts_and_counter_boundaries(self):
        for field, count in [('lanes',7),('nodes',25),('edges',41),('changes',10)]:
            value=spec()
            value['explain']['en']['scene'][field] *= count
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, field):
                fm_ste.check_explain(value['explain'])
        for counter in ['', 'x'*13, 12]:
            value=spec()
            value['explain']['en']['scene']['counter']=dict(label='Count',before=counter,after='1')
            with self.subTest(counter=counter), self.assertRaisesRegex(ValueError, 'counter.before'):
                fm_ste.check_explain(value['explain'])
        value=spec()
        for loc in value['explain'].values():
            sc=loc['scene']
            sc['lanes']=[dict(label='Flow') for _ in range(6)]
            sc['nodes']=[dict(id='n'+str(i),label='Input',lane=i%6,kind='step',state='same') for i in range(24)]
            sc['edges']=[dict(id='e'+str(i),**{'from':'n0','to':'n0'},state='same') for i in range(40)]
            sc['tokens']={'before':['e0']*24,'after':['e0']*24}
            sc['changes']=[dict(id='c'+str(i),text='The path works.',intents=[1]) for i in range(1,10)]
            sc['counter']=dict(label='Count',before='x'*12,after='y'*12)
        fm_ste.check_explain(value['explain'])

    def test_endpoint_states(self):
        for state in ['gone','new']:
            value=spec();sc=value['explain']['en']['scene']
            sc['nodes'][0].update(state=state,change='c1')
            with self.subTest(state=state), self.assertRaisesRegex(ValueError,'edges.state'):
                fm_ste.check_explain(value['explain'])
        value=spec();sc=value['explain']['en']['scene']
        sc['nodes'][0].update(state='gone',change='c1')
        sc['nodes'][1].update(state='new',change='c1')
        with self.assertRaisesRegex(ValueError,'cannot join'):
            fm_ste.check_explain(value['explain'])
        value=spec();sc=value['explain']['en']['scene']
        sc['edges'][0].update(state='gone',change='c1')
        with self.assertRaisesRegex(ValueError,'tokens.after'):
            fm_ste.check_explain(value['explain'])

    def test_remaining_scene_fields(self):
        cases=[('nodes.change',lambda s:s['nodes'][0].update(state='new')),
               ('tokens.before',lambda s:s['tokens'].update(before=['path']*25)),
               ('tokens.after',lambda s:s['tokens'].update(after=[])),
               ('edges.label',lambda s:s['edges'][0].update(label='one two three four five six seven')),
               ('counter.label',lambda s:s.update(counter=dict(label='one two three four five six seven',before='1',after='2'))),
               ('nodes.id',lambda s:s['nodes'][0].update(id='BAD')),
               ('nodes.kind',lambda s:s['nodes'][0].update(kind='unknown')),
               ('changes.intents',lambda s:s['changes'][0].update(intents=[1,1]))]
        for field,mutate in cases:
            value=spec();mutate(value['explain']['en']['scene'])
            with self.subTest(field=field),self.assertRaisesRegex(ValueError,field):fm_ste.check_explain(value['explain'])

    def test_locale_structure(self):
        value=spec()
        for loc in value['explain'].values():
            loc['intent'].append(dict(kind='fact',text='The path works.'))
            loc['done'].append(dict(kind='fact',text='Intent 2: The path works.' if loc is value['explain']['en'] else '意圖 2：路徑有效。'))
            sc=loc['scene'];sc['lanes'].append(dict(label='Flow'))
            sc['nodes'].append(dict(id='extra',label='Input',lane=0,kind='step',state='same'))
            sc['edges'].append(dict(id='loop',**{'from':'output','to':'output'},state='same'))
            sc['counter']=dict(label='Count',before='1',after='2')
        def rename(sc):
            sc['nodes'][0]['id']='different';sc['edges'][0]['from']='different'
        mutations=[rename,lambda sc:sc['lanes'].append(dict(label='Flow')),
                   lambda sc:sc['nodes'][0].update(lane=1),
                   lambda sc:sc['nodes'][0].update(kind='store'),
                   lambda sc:sc['nodes'][2].update(state='gone',change='c1'),
                   lambda sc:sc['tokens'].update(before=['path','loop']),
                   lambda sc:sc['counter'].update(before='0'),
                   lambda sc:sc['changes'][0].update(intents=[2])]
        for mutate in mutations:
            different=copy.deepcopy(value);mutate(different['explain']['en']['scene'])
            with self.subTest(scene=different['explain']['en']['scene']),self.assertRaisesRegex(ValueError,'locale structure'):
                fm_ste.check_explain(different['explain'])
        value['explain']['zh-TW'].pop('scene')
        with self.assertRaisesRegex(ValueError,'both locales'):
            fm_ste.check_explain(value['explain'])


@unittest.skipUnless((ROOT / 'bin/lib/fm_walk.py').is_file(),
                     'setup: fm_walk.py absent; helper cases are not behavioral base failures')
class Walk(unittest.TestCase):
    def setUp(self):
        import fm_walk
        self.walk = fm_walk
        self.value = spec()
        for loc in self.value['explain'].values():
            loc.pop('scene')
        self.diff = 'diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1 +1 @@\n-old\n+new\n'
        self.block = dict(hunk='a.py#R1-1', kind='code', note=dict(en='The path works.', **{'zh-TW': '路徑有效。'}))

    def check(self, blocks=None):
        text = '```walk\n' + json.dumps(dict(intents=[dict(intent=1, key=blocks or [self.block])])) + '\n```'
        return self.walk.check(text, self.value, self.diff, 'owner/repo', 1)

    def test_valid_rows(self):
        result = self.check()
        self.assertEqual('valid', result['status'])
        self.assertEqual(['del', 'add'], [r['type'] for r in result['intents'][0]['key'][0]['rows']])
        self.assertEqual([(1,None),(None,1)],[(r['old'],r['new']) for r in result['intents'][0]['key'][0]['rows']])
        self.assertEqual([], result['other'])

    def test_unknown_and_duplicate(self):
        self.block['hunk'] = 'unknown'
        self.assertEqual('unknown hunk id', self.check()['reason'])
        self.block['hunk'] = 'a.py#R1-1'
        self.assertEqual('duplicate key hunk', self.check([self.block, self.block])['reason'])

    def test_absent_duplicate_fence(self):
        self.assertEqual('absent', self.walk.check('APPROVE:T-001', self.value, self.diff)['status'])
        self.assertEqual('duplicate walk', self.walk.check('```walk\n{}\n```\n```walk\n{}\n```', self.value, self.diff)['reason'])


    def encoded(self, intents):
        return '```walk\n'+json.dumps(dict(intents=intents))+'\n```'

    def test_validation_classes(self):
        cases=[('invalid block fields',lambda b:b.pop('note')),
               ('invalid note fields',lambda b:b['note'].pop('zh-TW')),
               ('invalid note fields',lambda b:b['note'].update(extra='The path works.')),
               ('note fails STE',lambda b:b['note'].update(en='The path works. The input moves.')),
               ('line note outside block',lambda b:b.update(line_note={'line':2,'en':'The path works.','zh-TW':'路徑有效。'})),
               ('invalid line note fields',lambda b:b.update(line_note={'line':1,'en':'The path works.'})),
               ('invalid line note fields',lambda b:b.update(line_note={'line':'1','en':'The path works.','zh-TW':'路徑有效。'})),
               ('invalid line note fields',lambda b:b.update(line_note={'line':1,'en':'The path works.','zh-TW':'路徑有效。','extra':0})),
               ('proves on code block',lambda b:b.update(proves=['a.py#R1-1'])),
               ('invalid proves target',lambda b:b.update(kind='test',proves=['a.py#R1-1'])),
               ('step without scene',lambda b:b.update(step={'nodes':['input'],'edges':[]}))]
        for reason,mutate in cases:
            b=copy.deepcopy(self.block);mutate(b)
            with self.subTest(reason=reason):self.assertEqual(reason,self.check([b])['reason'])
        for number in [0,999,True]:
            self.assertEqual('intent out of range',self.walk.check(self.encoded([dict(intent=number,key=[])]),self.value,self.diff)['reason'])
        self.assertEqual('duplicate intent',self.walk.check(self.encoded([dict(intent=1,key=[])]*2),self.value,self.diff)['reason'])
        self.assertEqual('too many key blocks per intent',self.check([self.block]*6)['reason'])
        self.assertEqual('invalid JSON',self.walk.check('```walk\ninvalid\n```',self.value,self.diff)['reason'])

    def test_total_key_limit(self):
        for loc in self.value['explain'].values():loc['intent']=[dict(kind='fact',text='The path works.') for _ in range(9)]
        diff=''.join('diff --git a/f{0} b/f{0}\n--- a/f{0}\n+++ b/f{0}\n@@ -1 +1 @@\n-old\n+new\n'.format(i) for i in range(41))
        intents=[dict(intent=i+1,key=[dict(self.block,hunk='f%d#R1-1'%n) for n in range(i*5,min(i*5+5,41))]) for i in range(9)]
        self.assertEqual('too many key blocks',self.walk.check(self.encoded(intents),self.value,diff)['reason'])

    def test_scene_steps(self):
        self.value=spec()
        for reason,step in [('missing or invalid step',None),('empty step',{'nodes':[],'edges':[]}),('unknown step id',{'nodes':['bad'],'edges':[]})]:
            b=copy.deepcopy(self.block)
            if step is not None:b['step']=step
            with self.subTest(reason=reason):self.assertEqual(reason,self.check([b])['reason'])
        self.block['step']={'nodes':['input'],'edges':['path']}
        self.block['changes']=['c1']
        self.assertEqual('valid',self.check()['status'])
        self.value['explain']['en']['scene']['changes'][0]['intents']=[2]
        self.assertEqual('invalid block changes',self.check()['reason'])

    def test_side_lines_and_proves(self):
        self.diff='diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -10 +1 @@\n-old\n+new\n'
        self.block['line_note']={'line':10,'en':'The path works.','zh-TW':'路徑有效。'}
        self.assertEqual('line note outside block',self.check()['reason'])
        self.block.pop('line_note')
        self.diff+='diff --git a/test.py b/test.py\n--- a/test.py\n+++ b/test.py\n@@ -1 +1 @@\n-old\n+new\n'
        test=dict(self.block,hunk='test.py#R1-1',kind='test',proves=['a.py#R1-1'])
        self.assertEqual('valid',self.check([self.block,test])['status'])
        for loc in self.value['explain'].values():loc['intent']=[dict(kind='fact',text='The path works.')]*2
        duplicate=self.encoded([dict(intent=1,key=[self.block]),dict(intent=2,key=[self.block])])
        self.assertEqual('duplicate key hunk',self.walk.check(duplicate,self.value,self.diff)['reason'])

    def test_long_window(self):
        self.diff='diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -0,0 +1,120 @@\n'+''.join('+row\n' for _ in range(120))
        self.block.update(hunk='a.py#R1-120',line_note={'line':110,'en':'The path works.','zh-TW':'路徑有效。'})
        block=self.check()['intents'][0]['key'][0]
        self.assertEqual(80,len(block['rows']))
        self.assertEqual({'before':40,'after':0},block['truncated'])
        self.assertIn(110,[r['new'] for r in block['rows']])

    def test_large_complement_and_special_ids(self):
        self.diff=''.join('diff --git a/f{0} b/f{0}\n--- a/f{0}\n+++ b/f{0}\n@@ -1 +1 @@\n-old\n+new\n'.format(i) for i in range(400))
        self.diff+=('diff --git a/gone b/gone\n--- a/gone\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n'
                    'diff --git a/image b/image\nBinary files a/image and b/image differ\n'
                    'diff --git a/mode b/mode\nold mode 100644\nnew mode 100755\n'
                    'diff --git a/empty b/empty\nnew file mode 100644\nindex 0000000..e69de29\n'
                    'diff --git "a/space \\303\\251" "b/space \\303\\251"\n--- "a/space \\303\\251"\n+++ "b/space \\303\\251"\n@@ -1 +1 @@\n-old\n+new\n')
        blocks=[dict(self.block,hunk='f%d#R1-1'%i) for i in range(3)]
        result=self.check(blocks)
        self.assertEqual('valid',result['status'])
        self.assertEqual(402,sum(f['hunks'] for f in result['other']))
        self.assertEqual(sorted(f['file'] for f in result['other']),[f['file'] for f in result['other']])
        canonical=self.walk.hunks(self.diff)
        for identifier in ['gone#L1-1','image#binary','mode#mode','empty#empty','space é#R1-1']:
            self.assertIn(identifier,canonical)

    def test_record_selection(self):
        from unittest.mock import patch
        head='a'*40; old='b'*40
        eligible=dict(verdict='APPROVE',signature='signed',head=head,base='c'*40,patch='d'*64,text='APPROVE:T-001')
        attach=lambda records:self.walk.attach(records,head,self.value,ROOT)
        self.assertEqual('no local review',attach([])['reason'])
        self.assertEqual('no local approval',attach([dict(verdict='REJECT')])['reason'])
        for field in ['head','base','patch']:
            for value in [None,'']:
                broken=dict(eligible)
                if value is None:broken.pop(field)
                else:broken[field]=value
                with self.subTest(field=field,value=value):
                    self.assertEqual('verdict has no source binding',attach([broken])['reason'])
                    self.assertEqual(dict(status='stale',reviewed_head=old),attach([dict(eligible,head=old),broken]))
        unsigned=dict(eligible);unsigned.pop('signature')
        self.assertEqual('verdict has no source binding',attach([unsigned])['reason'])
        self.assertEqual('no walk',attach([eligible,unsigned])['reason'])
        text=self.encoded([dict(intent=1,key=[self.block])])
        with patch.object(self.walk,'canonical_diff',return_value=self.diff):
            result=attach([dict(eligible,text=text,provenance={'level':'legacy'})])
            self.assertEqual('valid',result['status'])
            self.assertEqual((head,eligible['base'],eligible['patch']),(result['head'],result['base'],result['patch']))
            self.assertEqual('unknown hunk id',attach([dict(eligible,text=text.replace('a.py#R1-1','unknown'))])['reason'])
        with patch.object(self.walk,'canonical_diff',side_effect=ValueError):
            self.assertEqual('diff unavailable',attach([dict(eligible,text=text)])['reason'])

    def test_comment_projection(self):
        text='APPROVE:T-001\n'+self.encoded([dict(intent=1,key=[self.block])])
        projected=self.walk.project_comment(text)
        self.assertIn('APPROVE:T-001',projected)
        self.assertIn('Code walk retained with the evidence (1 key blocks).',projected)
        self.assertNotIn('```walk',projected)
        self.assertNotIn('The path works.',projected)


# Shared producer fixture: tests/lib/card_refs.py, tests/lib/ste_cases.py,
# tests/decide.test.sh, tests/lib/project-storage.sh.
_saved_argv=sys.argv[:]
sys.argv.insert(1,str(ROOT))
import card_refs as producer
sys.argv[:]=_saved_argv

class MergeRequests(unittest.TestCase):
    setUp=producer.StockRequests.setUp
    write=producer.StockRequests.write
    git=producer.StockRequests.git
    commit_spec=producer.StockRequests.commit_spec
    request=producer.StockRequests.request
    pending=producer.StockRequests.pending

    def stored(self):
        result=self.request()
        self.assertEqual(0,result.returncode,result.stderr)
        details=json.loads(self.pending().read_text())['details']
        self.assertIn('walk',details,'every merge request records a presentation-only walk status')
        return details['walk']

    def store(self):
        from fm_evidence import Store
        project=subprocess.check_output(['bash','-c','. "$1/bin/fm-config.sh"; fm_storage_init "$1" || exit; fm_evidence_project','fixture',str(self.root)],text=True).strip()
        return Store(self.root/'state',project,'T-242')

    def approval(self, **fields):
        values=dict(verdict='APPROVE',base=self.base,patch='d'*64,provenance={'level':'legacy'})
        values.update(fields)
        for field in ['base','patch']:
            if values.get(field) is None:values.pop(field,None)
        head=values.pop('head',self.head);text=values.pop('text','APPROVE:T-242')
        return self.store().append('verdict',1,'reviewer',head,text,**values)

    def test_no_local_review_does_not_refuse_request(self):
        self.commit_spec(self.legacy)
        self.assertEqual(dict(status='absent',head=self.head,reason='no local review'),self.stored())

    def test_missing_helper_never_refuses_legacy(self):
        self.commit_spec(self.legacy)
        (self.root/'bin/lib/fm_walk.py').unlink(missing_ok=True)
        self.assertEqual(dict(status='unavailable',reason='walk helper missing'),self.stored())

    def test_no_refs_helper_still_selects_absent(self):
        self.commit_spec(self.legacy)
        (self.root/'bin/lib/fm_card_refs.py').unlink(missing_ok=True)
        self.assertEqual('no local review',self.stored()['reason'])

    def test_unsigned_historical_approval_is_ignored(self):
        self.commit_spec(self.legacy)
        store=self.store();store.directory.mkdir(parents=True,exist_ok=True)
        record=dict(kind='verdict',project=store.project,task='T-242',round=1,actor='reviewer',time='2026-01-01T00:00:00Z',head=self.head,base=self.base,patch='d'*64,verdict='APPROVE',text='APPROVE:T-242',provenance={'level':'legacy'})
        path=store.directory/'00000001-history.json';path.write_text(json.dumps(record))
        original=path.read_bytes()
        self.assertEqual('verdict has no source binding',self.stored()['reason'])
        self.assertEqual(original,path.read_bytes())

    def test_scene_injection_without_change_points(self):
        value=spec();value['id']='T-242'
        self.commit_spec(value)
        result=self.request();self.assertEqual(0,result.returncode,result.stderr)
        stored=json.loads(self.pending().read_text())
        for lang in ['en','zh-TW']:
            self.assertIn('scene',stored['details'][lang],'merge requests inject the approved scene without change_points')
            self.assertEqual(value['explain'][lang]['scene'],stored['details'][lang]['scene'])
        details=copy.deepcopy(self.details)
        for lang in ['en','zh-TW']:
            details[lang]['scene']=scene();details[lang]['scene']['lanes'][0]['label']='Other'
        result=self.request(details=details)
        self.assertNotEqual(0,result.returncode)
        self.assertIn('scene mismatch with spec',result.stderr)

    def test_missing_helper_never_refuses_enriched(self):
        details=copy.deepcopy(self.details)
        for lang in ['en','zh-TW']:
            for field in ['change_points','door','check']:
                details[lang][field]=copy.deepcopy(self.enriched['explain'][lang][field])
            details[lang]['intent']=copy.deepcopy(self.enriched['explain'][lang]['intent'])
        (self.root/'bin/lib/fm_walk.py').unlink(missing_ok=True)
        result=self.request(details=details);self.assertEqual(0,result.returncode,result.stderr)
        self.assertEqual({'status':'unavailable','reason':'walk helper missing'},json.loads(self.pending().read_text())['details']['walk'])

    @unittest.skipUnless((ROOT/'bin/lib/fm_walk.py').is_file(),'setup: fm_walk.py absent; invalid helper records need the new helper')
    def test_invalid_walk_and_missing_diff_are_presentation_only(self):
        self.commit_spec(self.legacy)
        text='APPROVE:T-242\n```walk\nnot json\n```'
        self.approval(text=text)
        self.assertEqual('invalid JSON',self.stored()['reason'])
        self.approval(text=text,base='e'*40)
        self.assertEqual('diff unavailable',self.stored()['reason'])

    def test_built_details_receive_scene_from_pin(self):
        from fm_merge_details import build
        value=spec();value['id']='T-242';self.commit_spec(value)
        dispatch=copy.deepcopy(self.details)
        dispatch['en']['title']='Dispatch T-242: The check passes.'
        dispatch['zh-TW']['title']='派工 T-242：檢查通過。'
        for lang in ['en','zh-TW']:
            dispatch[lang].update(value['explain'][lang])
        self.write('state/decisions/D-firstmate-workflow-T242-1.json',json.dumps(dict(task='T-242',project='firstmate-workflow',purpose='dispatch',chosen='A',details=dispatch)))
        built=build(self.root/'state','firstmate-workflow','T-242',7)
        self.assertNotIn('scene',built['en'])
        result=self.request(details=built);self.assertEqual(0,result.returncode,result.stderr)
        card=json.loads(self.pending().read_text())
        for lang in ['en','zh-TW']:
            self.assertEqual(value['explain'][lang]['scene'],card['details'][lang]['scene'])

    def test_no_approval_and_legacy_head(self):
        self.commit_spec(self.legacy)
        self.approval(verdict='REJECT',text='REJECT:T-242')
        self.assertEqual('no local approval',self.stored()['reason'])
        self.approval(head='')
        self.assertEqual('verdict has no source binding',self.stored()['reason'])

    @unittest.skipUnless((ROOT/'bin/lib/fm_walk.py').is_file(),'setup: fm_walk.py absent; bound helper records need the new helper')
    def test_complete_binding_without_binding_object_and_stale(self):
        self.commit_spec(self.legacy)
        self.approval()
        self.assertEqual(dict(status='absent',head=self.head,reason='no walk'),self.stored())
        previous=self.head
        self.write('src/a.py','next\n');self.commit_spec(self.legacy)
        self.assertEqual(dict(status='stale',reviewed_head=previous),self.stored())

    @unittest.skipUnless((ROOT/'bin/lib/fm_walk.py').is_file(),'setup: fm_walk.py absent; bound helper records need the new helper')
    def test_signed_source_defects_are_ineligible_before_head(self):
        self.commit_spec(self.legacy)
        for field in ['base','patch']:
            for value in [None,'']:
                with self.subTest(field=field,value=value):
                    self.approval(**{field:value})
                    self.assertEqual('verdict has no source binding',self.stored()['reason'])
        self.approval(head=self.base)
        self.assertEqual(dict(status='stale',reviewed_head=self.base),self.stored())

    @unittest.skipUnless((ROOT/'bin/lib/fm_walk.py').is_file(),'setup: fm_walk.py absent; bound helper records need the new helper')
    def test_walk_card_and_records_are_immutable(self):
        value=spec();value['id']='T-242'
        for loc in value['explain'].values():loc.pop('scene')
        self.commit_spec(value)
        text='APPROVE:T-242\n```walk\n'+json.dumps({'intents':[{'intent':1,'key':[{'hunk':'src/a.py#R1-1','kind':'code','note':{'en':'The path works.','zh-TW':'路徑有效。'}}]}]})+'\n```'
        self.approval(text=text)
        files=list(self.store().directory.glob('*.json'))
        before={p:p.read_bytes() for p in files}
        result=self.stored();self.assertEqual('valid',result['status'])
        first=self.pending();original=first.read_bytes();old_head=self.head
        self.write('src/a.py','later\n');self.commit_spec(value)
        self.approval(text=text)
        self.assertEqual(self.head,self.stored()['head'])
        self.assertEqual(original,first.read_bytes())
        for p,data in before.items():self.assertEqual(data,p.read_bytes())
        self.assertNotEqual(old_head,self.head)
        reviewed=self.head
        self.git('commit','--allow-empty','-qm','same patch new head')
        self.head=self.git('rev-parse','HEAD').strip()
        self.write('prs.jsonl',json.dumps(dict(number=7,state='OPEN',headRefOid=self.head,headRefName='t-242-fixture',title='T-242: fixture'))+'\n')
        self.assertEqual(dict(status='stale',reviewed_head=reviewed),self.stored())
        self.assertEqual(original,first.read_bytes())


    def test_external_walk_is_private_and_uses_target_diff(self):
        from fm_evidence import Store
        home=Path((self.root/'.fixture-fm-home').read_text().strip())
        workspace=home/'projects/beta';target=workspace/'repo'
        target.parent.mkdir(parents=True)
        subprocess.run(['git','clone','--quiet','--local',str(self.root),str(target)],check=True,capture_output=True)
        private=spec();private['id']='T-242'
        (workspace/'tasks').mkdir(parents=True)
        (workspace/'tasks/T-242.json').write_text(json.dumps(private))
        self.write('config.yaml','home: '+str(home)+'\ndefault_project: alpha\nprojects:\n  alpha:\n    repo: .\n    github: owner/engine\n    base: main\n    required_check: ci\n  beta:\n    github: owner/private\n    base: main\n    required_check: ci\n')
        text='APPROVE:T-242\n```walk\n'+json.dumps({'intents':[{'intent':1,'key':[{'hunk':'src/a.py#R1-1','kind':'code','note':{'en':'The private path works.','zh-TW':'私人路徑有效。'},'step':{'nodes':['input'],'edges':['path']},'changes':['c1']}]}]})+'\n```'
        store=Store(workspace/'state','beta','T-242',external=True)
        store.append('verdict',1,'reviewer',self.head,text,verdict='APPROVE',base=self.base,patch='d'*64,provenance={'level':'legacy'})
        snapshots={p:p.read_bytes() for p in store.directory.glob('*.json')}
        self.env['FM_PROJECT']='beta'
        result=self.request('D-beta-T242-1');self.assertEqual(0,result.returncode,result.stderr)
        card=json.loads((workspace/'state/pending/D-beta-T242-1.json').read_text())
        self.assertIn('walk',card['details'],'external merge requests attach privately')
        self.assertEqual('valid',card['details']['walk']['status'])
        self.assertIn('owner/private',card['details']['walk']['intents'][0]['key'][0]['url'])
        self.assertEqual(private['explain']['en']['scene'],card['details']['en']['scene'])
        for p,data in snapshots.items():self.assertEqual(data,p.read_bytes())
        for event in (workspace/'state').glob('events*.jsonl'):
            self.assertNotIn('The private path works.',event.read_text())
            self.assertNotIn('"scene"',event.read_text())
            self.assertNotIn('"walk"',event.read_text())
        for wake in home.rglob('wake.d/*.json'):
            self.assertNotIn('The private path works.',wake.read_text())
            self.assertNotIn('"scene"',wake.read_text())
        self.assertFalse((self.root/'state/evidence/beta/T-242').exists())

if __name__ == '__main__':
    unittest.main()
