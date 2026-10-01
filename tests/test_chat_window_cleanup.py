"""Actual cleanup + resolver methods with fake AX values/actions, never GUI.

The typed decoder executes on real Foundation arrays/String/NSNull and fake AX
handles. Source functions are extracted verbatim; only OS boundaries/sleep are
replaced. This does not establish Kakao's live AXSheets support or key effects.
"""
import hashlib,json,re,subprocess,tempfile,unittest
from pathlib import Path
from test_auth_ack_structure_scope import block,swiftc_command
R=Path(__file__).resolve().parents[1]

def method(source,name):
 m=re.search(r'    (?:private |public )?func '+name+r'\b',source);assert m,name
 return block(source,m.start()).replace('private func ','func ').replace('public func ','func ')

def fixture():
 resolver=(R/'Sources/kmsg/KakaoTalk/ChatWindowResolver.swift').read_text()
 image=(R/'Sources/kmsg/Commands/SendImageCommand.swift').read_text()
 send=(R/'Sources/kmsg/Commands/SendCommand.swift').read_text()
 app=(R/'Sources/kmsg/KakaoTalk/KakaoTalkApp.swift').read_text()
 helper=(R/'Sources/kmsg/KakaoTalk/ChatWindowCleanup.swift').read_text()
 helper=re.sub(r'^import (?:AppKit|ApplicationServices.HIServices)\n','',helper,flags=re.M)
 base=(R/'tests/fixtures/chat_window_cleanup.swift').read_text()
 replacements={
 'APP':'\n'.join(method(app,n) for n in ['currentUsableWindow','ensureWindowReopened']),
 'CLOSE':'\n'.join(method(resolver,n) for n in ['closeWindow','supportsAction','tryRaiseWindow','findCloseButton','waitForWindowClosed']),
 'IMAGE':'\n'.join(method(image,n) for n in ['clearLeftoverDraft','closeWindowsIfNeeded','closeChatWindowWithRetry']),
 'SEND':'\n'.join(method(send,n) for n in ['closeWindowsIfNeeded','closeChatWindowWithRetry']),
 }
 # Execute the command's real defer body for failure/success milestone cases.
 start=image.index('            defer {',image.index('let draftState ='))
 defer_body=block(image,start)
 caller='\n func executeCleanupDefer(_ resolution:ChatWindowResolution,verified:Bool,pasted:Bool,fail:Bool)throws {\n  let profiler=PhaseProfiler(),runner=AXActionRunner(),kakao=KakaoTalkApp(),chatWindowResolver=ChatWindowResolver()\n  let draftState=ChatWindowCleanup.ImageDraftState(window: resolution.window);draftState.identityVerified=verified;draftState.pasteDispatched=pasted;draftState.clipboardPrepared=pasted\n  let cleanup=ChatWindowCleanup(kakao:kakao,runner:runner)\n'+defer_body+'\n  if fail { throw FixtureError.failure }\n }\n'
 replacements['IMAGE'] += caller
 for k,v in replacements.items():base=base.replace('// '+k,v)
 resolution=resolver[resolver.index('enum ChatWindowResolutionMethod'):resolver.index('private enum ChatWindowFailureCode')]
 return (resolution+base+helper+CASES).replace('Thread.sleep','fixtureSleep')

CASES=r'''
var results:[[String:Any]]=[]
let cases=["composer-appears","composer-replaced","caption-first","parent-incomplete","replacement-caption","system-input-mismatch","value-wrong-type","value-unavailable","pid-failure","normal-owned-sheet","normal-no-escape-effect","escape-closes-target","already-absent","draft-focus-fails","keep-no-sheet","keep-owned-sheet","keep-focus-fails","unknown-inventory","unknown-after-close","stale-inventory-after-close","inventory-no-value","inventory-unsupported","inventory-cannot-complete","inventory-malformed","inventory-wrong-type","inventory-process-changed","malformed-window-array","pre-verify-failure","pre-paste-failure","paste-uncertain","attachment-not-text","external-app-frontmost","sheet-unknown","sheet-persists","sheet-replaced","new-sheet-before-delete","missing-input","last-standalone","race-before-delete","race-before-command-w","button-route","command-w-route","blocked-close-no-modal"]
for name in cases {
 for keep in [false,true] {
  world.reset(name)
  let t=world.target!,r=AXActionRunner(),p=PhaseProfiler(),app=KakaoTalkApp(),resolver=ChatWindowResolver()
  let cleanup=ChatWindowCleanup(kakao:app,runner:r)
  let state=ChatWindowCleanup.ImageDraftState(window: t);state.identityVerified=world.targetAuthorized;state.clipboardPrepared=world.pasteDispatched;state.pasteDispatched=world.pasteDispatched
  let before=cleanup.presence(of:t).rawValue
  let cmd=ImageCleanup(keepWindow:keep)
  cmd.clearLeftoverDraft(in:t,cleanup:cleanup,state:state,profiler:p)
  if state.identityVerified {cmd.closeWindowsIfNeeded(resolution:ChatWindowResolution(window:t,method:.openedViaChatList),kakao:app,resolver:resolver,runner:r,profiler:p)}
  let draft=world.notes["draft.result",default:[]].last ?? "missing"
  results.append(["case":name,"keep":keep,"presence":before,"draft":draft,"close":world.notes["close.result",default:[]].last ?? "unverified","main":world.present(1),"target":world.present(2),"targetTextResidual":world.draft[2,default:true],"attachmentResidual":world.attachmentResidual,"foreignClears":world.clears.filter{$0 != 2}.count,"foreignCloses":world.closed.filter{$0 != 2}.count,"keys":[world.escaped,world.cmdA,world.delete,world.cmdw],"notes":world.notes,"calls":world.ipc,"events":world.events])
 }
}
for verified in [false,true] {
 for pasted in [false,true] {
  for fail in [false,true] {
   world.reset("normal-no-escape-effect")
   let command=ImageCleanup(keepWindow:false),resolution=ChatWindowResolution(window:world.target,method:.openedViaChatList)
   var failed=false
   do{try command.executeCleanupDefer(resolution,verified:verified,pasted:pasted,fail:fail)}catch{failed=true}
   results.append(["case":"actual-command-defer","verified":verified,"pasted":pasted,"failureRequested":fail,"failed":failed,"keys":[world.escaped,world.cmdA,world.delete,world.cmdw],"textResidual":world.draft[2,default:true],"target":world.present(2),"draft":world.notes["draft.result",default:[]].last ?? "missing"])
  }
 }
}
for changed in [false,true] {
 world.reset("normal-no-escape-effect")
 let target=world.target!,runner=AXActionRunner(),profiler=PhaseProfiler(),cleanup=ChatWindowCleanup(kakao:KakaoTalkApp(),runner:runner)
 let state=ChatWindowCleanup.ImageDraftState(window:target);state.identityVerified=true;state.clipboardPrepared=true
 cleanup.rememberPasteInput(in:target,state:state)
 state.pasteDispatched=true
 if changed { world.inputs[2]=Node(24,2,"input") }
 let start=world.events.count
 let outcome=cleanup.clearImageDraft(in:target,state:state,allowWindowClose:false,profiler:profiler)
 let actions=Array(world.events.dropFirst(start))
 results.append(["case":"paste-witness","changed":changed,"draft":outcome.rawValue,"findInputCalls":actions.filter{($0["kind"] as? String)=="findInput"}.count,"source":world.notes["draft.inputSource",default:[]].last ?? "missing","keys":[world.escaped,world.cmdA,world.delete,world.cmdw]])
}
// Repeat absent closure is idempotent even when the previous focused window is main.
world.reset("already-absent")
let r=ChatWindowResolver();let one=r.closeWindow(world.target);let two=r.closeWindow(world.target)
results.append(["case":"idempotent","one":one,"two":two,"escape":world.escaped,"cmdw":world.cmdw,"main":world.present(1)])
print("RESULT:"+String(data:try JSONSerialization.data(withJSONObject:results,options:[.sortedKeys]),encoding:.utf8)!)
'''

class CleanupTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.source=fixture()
  with tempfile.TemporaryDirectory(prefix='cleanup-actual-') as d:
   d=Path(d);(d/'main.swift').write_text(cls.source)
   p=subprocess.run([*swiftc_command(),str(d/'main.swift'),'-o',str(d/'test')],capture_output=True,text=True)
   if p.returncode:raise AssertionError(p.stderr)
   p=subprocess.run([str(d/'test')],capture_output=True,text=True,check=True)
   cls.rows=json.loads(next(x[7:] for x in p.stdout.splitlines() if x.startswith('RESULT:')))
 @classmethod
 def row(cls,c,k=False):return next(x for x in cls.rows if x['case']==c and x.get('keep')==k)
 def test_idempotent_absent(self):
  r=next(x for x in self.rows if x['case']=='idempotent');self.assertTrue(r['one'] and r['two'] and r['main']);self.assertEqual(r['escape']+r['cmdw'],0)
 def test_escape_target_absence_preserves_main(self):
  r=self.row('escape-closes-target');self.assertTrue(r['main']);self.assertFalse(r['target']);self.assertEqual(r['keys'],[1,0,0,0]);self.assertEqual(r['draft'],'target-absent');self.assertEqual(r['close'],'verified')
 def test_keep_never_escapes_plain_window(self):
  r=self.row('keep-no-sheet',True);self.assertTrue(r['target']);self.assertEqual(r['keys'][0],0);self.assertEqual(r['draft'],'text-empty')
 def test_normal_owned_sheet_and_draft(self):
  for keep in [False,True]:
   r=self.row('normal-owned-sheet',keep);self.assertEqual(r['draft'],'text-empty');self.assertEqual(r['keys'][:3],[1,1,1]);self.assertEqual(r['foreignClears']+r['foreignCloses'],0)
 def test_failed_focus_never_deletes(self):
  for k in [False,True]:
   r=self.row('draft-focus-fails',k);self.assertEqual(r['keys'][1:3],[0,0]);self.assertEqual(r['foreignClears'],0)
 def test_pre_paste_user_draft_preserved(self):
  for c in ['pre-verify-failure','pre-paste-failure']:
   for k in [False,True]:
    r=self.row(c,k);self.assertTrue(r['targetTextResidual']);self.assertEqual(r['keys'][1:3],[0,0])
  self.assertTrue(self.row('pre-verify-failure')['target'])
 def test_typed_bad_inventory_is_not_absent(self):
  for c in ['unknown-inventory','inventory-no-value','inventory-unsupported','inventory-cannot-complete','inventory-malformed','inventory-wrong-type','inventory-process-changed','malformed-window-array']:
   r=self.row(c);self.assertEqual(r['presence'],'unknown');self.assertEqual(r['keys'],[0,0,0,0]);self.assertEqual(r['close'],'unconfirmed')
 def test_error_after_close_not_false_verified(self):
  self.assertEqual(self.row('unknown-after-close')['close'],'unconfirmed')
 def test_external_foreground_never_keyed(self):
  for k in [False,True]:self.assertEqual(self.row('external-app-frontmost',k)['keys'],[0,0,0,0])
 def test_changed_or_remaining_sheet_blocks_delete(self):
  for c in ['sheet-persists','sheet-replaced','new-sheet-before-delete']:
   for k in [False,True]:self.assertEqual(self.row(c,k)['keys'][2],0)
 def test_unknown_sheet_does_not_remove_close_authority(self):
  r=self.row('sheet-unknown');self.assertEqual(r['keys'][0],1)
 def test_text_empty_not_attachment_proof(self):
  r=self.row('attachment-not-text',True);self.assertEqual(r['draft'],'text-empty');self.assertTrue(r['attachmentResidual']);self.assertEqual(r['notes']['draft.attachment'],['unverified'])
 def test_foreign_effect_only_explicit_last_key_race(self):
  for r in self.rows:
   if 'keep' not in r or r['case'].startswith('race-'):continue
   self.assertEqual(r['foreignClears']+r['foreignCloses'],0,r['case'])
 def test_global_race_remains_explicit(self):
  self.assertGreater(self.row('race-before-delete',True)['foreignClears'],0)
 def test_caption_and_unknown_parent_never_selected(self):
  for c in ['caption-first','parent-incomplete','replacement-caption']:
   for k in [False,True]:self.assertEqual(self.row(c,k)['keys'][1:3],[0,0])
 def test_system_focused_input_required(self):
  for k in [False,True]:self.assertEqual(self.row('system-input-mismatch',k)['keys'][1:3],[0,0])
 def test_typed_value_errors_not_empty(self):
  for c in ['value-wrong-type','value-unavailable']:self.assertEqual(self.row(c,True)['draft'],'text-unconfirmed')
 def test_pid_error_not_absent(self):
  r=self.row('pid-failure');self.assertEqual(r['presence'],'unknown');self.assertEqual(r['keys'],[0,0,0,0])
 def test_actual_command_defer_preserves_success_failure(self):
  rows=[x for x in self.rows if x['case']=='actual-command-defer']
  self.assertEqual(len(rows),8)
  for r in rows:
   self.assertEqual(r['failureRequested'],r['failed'])
   if not r['verified']:
    self.assertEqual(r['keys'],[0,0,0,0]);self.assertTrue(r['target']);self.assertTrue(r['textResidual'])
   elif not r['pasted']:self.assertTrue(r['textResidual'])
 def test_post_sheet_composer_appearance_preserves_cleanup(self):
  for c in ['composer-appears','composer-replaced']:
   for keep in [False,True]:
    r=self.row(c,keep);self.assertEqual(r['draft'],'text-empty');self.assertEqual(r['keys'][:3],[1,1,1])
 def test_paste_witness_saves_walk_but_is_revalidated(self):
  rows=[x for x in self.rows if x['case']=='paste-witness']
  self.assertEqual(len(rows),2)
  for r in rows:
   self.assertEqual(r['draft'],'text-empty')
   self.assertEqual(r['findInputCalls'],1 if r['changed'] else 0)
   self.assertEqual(r['source'],'after-escape' if r['changed'] else 'before-paste')
 def test_optional_witness_before_final_paste_focus_guard(self):
  source=(R/'Sources/kmsg/Commands/SendImageCommand.swift').read_text()
  body=method(source,'sendImageToWindow')
  self.assertLess(body.index('rememberPasteInput('),body.index('let focusedNow ='))
  self.assertLess(body.index('guard let focusedNow'),body.index('runner.pressPaste()'))
  self.assertLess(body.index('draftState.pasteDispatched = true'),body.index('runner.pressPaste()'))
 def test_fixed_metadata(self):
  self.assertNotIn('PRIVATE-',json.dumps(self.rows))
  self.assertLess(len(self.rows),110)

if __name__=='__main__':unittest.main()
