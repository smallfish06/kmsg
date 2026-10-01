import Foundation
import CoreFoundation
let kAXButtonRole="button", kAXTextAreaRole="textArea", kAXRaiseAction="AXRaise", kAXCloseButtonAttribute="closeButton"
enum FixtureError: Error { case failure }
enum AuthenticationMode { case automaticIfNeeded, promptForFreshCredentials }
enum AuthenticationOutcome: String { case alreadyAuthenticated, loggedIn }
struct LoginForm {}
struct DecryptedCredentials { let identifier="PRIVATE-FIXTURE";let password="PRIVATE-FIXTURE" }
final class Node: NSObject {
 let id:Int; let owner:Int; let kind:String; var actions:[String]=[]
 init(_ id:Int,_ owner:Int,_ kind:String){self.id=id;self.owner=owner;self.kind=kind}
}
struct UIElement {
 let node:Node
 var axElement:Node{node}
 static func systemWide()->UIElement{UIElement(Node(-1,-1,"system"))}
 init(_ n:Node){node=n};init(_ other:UIElement){node=other.node}
 var title:String?{world.event("title",node.id);return node.kind == "closeButton" ? "close" : "PRIVATE-FIXTURE"}
 var identifier:String?{world.event("identifier",node.id);return node.kind == "closeButton" ? "close" : nil}
 var axDescription:String?{world.event("description",node.id);return nil}
 func actionNames() throws -> [String]{world.event("actionNames",node.id);guard world.isLive(node) else{throw FixtureError.failure};return node.actions}
 func performAction(_ s:String)throws{
  world.event(s,node.id);guard world.isLive(node) else{throw FixtureError.failure}
  if s=="AXRaise" {if world.raiseFocus{world.focus=node.owner};return}
  if s=="AXClose" {world.close(node.owner,via:"AXClose");return}
  throw FixtureError.failure
 }
 func press()throws{world.event("press",node.id);guard world.isLive(node) else{throw FixtureError.failure};world.close(node.owner,via:"button")}
 func focus()throws{world.event("focusInput",node.id);guard world.isLive(node),world.inputFocusWorks else{throw FixtureError.failure};world.focus=node.owner;world.focusInput=node.id}
 func attribute<T>(_ name:String)throws->T{
  world.event(name,node.id)
  var raw:AnyObject?
  if node.id == -1 {
   if name == kAXFocusedUIElementAttribute { raw=world.systemInputMismatch ? world.inputs[1]:world.globalFocus.flatMap{world.inputs[$0]} }
  }else if node.id==0 {
   switch name {
   case kAXWindowsAttribute:
    if world.inventoryFault{throw FixtureError.failure}
    if world.inventoryStatus == "inventory-malformed" { raw=NSNull();break }
    if world.inventoryStatus == "inventory-wrong-type" { raw="not-an-array" as NSString;break }
    if world.inventoryStatus != "ok"{throw FixtureError.failure}
    var values=world.windows.map{$0.node}
    if world.staleInventoryAfterClose && !world.present(2){values.append(world.target.node)}
    raw=values as NSArray
    if world.malformedWindowArray{raw=[world.target.node,NSNull()] as NSArray}
   case kAXFocusedWindowAttribute:raw=world.windows.first{$0.node.id==world.focus}?.node
   case kAXFocusedUIElementAttribute:raw=world.focus.flatMap{world.inputs[$0]}
   default:break
   }
  }else{
   guard world.isLive(node) else{throw FixtureError.failure}
   switch name {
   case kAXSheetsAttribute:
    if world.sheetUnknown{throw FixtureError.failure}
    if let owner=world.sheetOwner {
      let sheet=world.sheets[owner]!
      raw=[sheet] as NSArray
    }else{raw=[] as NSArray}
   case kAXWindowAttribute:raw=world.windows.first{$0.node.id==node.owner}?.node
   case kAXParentAttribute:
    if world.parentUnavailable{throw FixtureError.failure}
    raw=(world.inputUnderSheet && node.kind=="input") ? world.sheets[2]:world.windows.first{$0.node.id==node.owner}?.node
   case kAXRoleAttribute:raw=(node.kind=="input" ? kAXTextAreaRole:node.kind) as NSString
   case kAXValueAttribute:
    if world.valueUnavailable{throw FixtureError.failure}
    raw=world.valueWrongType ? NSNumber(value:0):(world.draft[node.owner,default:true] ? "PRIVATE-FIXTURE":"") as NSString
   case kAXCloseButtonAttribute:
    if world.closeRoute=="button"{raw=Node(node.owner*10+1,node.owner,"closeButton")}
   default:break
   }
  }
  guard let value=raw as? T else{throw FixtureError.failure};return value
 }
 func attributeOptional<T>(_ name:String)->T?{try? attribute(name)}
 func findAll(role:String,limit:Int,maxNodes:Int)->[UIElement]{
  world.event(role==kAXTextAreaRole ? "findInput":"findButtons",node.id)
  guard world.isLive(node) || world.staleInputReadable else{return []}
  if role==kAXTextAreaRole,world.inputAvailable{return [UIElement(world.inputs[node.owner]!)]}
  return []
 }
}
typealias AXUIElement=Node
let kAXWindowsAttribute="windows", kAXFocusedWindowAttribute="focusedWindow", kAXFocusedUIElementAttribute="focusedInput", kAXWindowAttribute="window", kAXParentAttribute="parent", kAXSheetsAttribute="sheets", kAXRoleAttribute="role", kAXSheetRole="sheet", kAXValueAttribute="value"
enum AXError { case success, cannotComplete }
func AXUIElementGetTypeID()->CFTypeID{99999}
func CFGetTypeID(_ value:CFTypeRef)->CFTypeID{value is Node ? AXUIElementGetTypeID():CoreFoundation.CFGetTypeID(value)}
func AXUIElementGetPid(_ node:Node,_ pid:inout pid_t)->AXError{world.event("getPID",node.id);if world.pidFailure{return .cannotComplete};pid=100;return .success}
func CFEqual(_ a:Node,_ b:Node)->Bool{a===b}
final class NSRunningApplication { let processIdentifier:pid_t;init(_ p:pid_t){processIdentifier=p} }
final class NSWorkspace { static let shared=NSWorkspace();var frontmostApplication:NSRunningApplication?{NSRunningApplication(world.foreignApp ? 200:100)} }

final class World {
 var malformedWindowArray=false,sheetUnknown=false,sheetPersists=false,sheetReplaces=false,newSheetBeforeDelete=false
 var inputUnderSheet=false,parentUnavailable=false,replacementInput=false,systemInputMismatch=false,valueWrongType=false,valueUnavailable=false,pidFailure=false
 var inputAppearsAfterEscape=false,composerReplaced=false
 var sheets:[Int:Node]=[:]
 var windows:[UIElement]=[];var inputs:[Int:Node]=[:];var target:UIElement!
 var focus:Int?=nil;var focusInput:Int?=nil;var sheetOwner:Int?=nil
 var raiseFocus=true,inputFocusWorks=true,inputAvailable=true,closeAllowed=true,escapeCloses=true
 var staleInputReadable=false,inventoryFault=false,inventoryFaultAfterClose=false,staleInventoryAfterClose=false
 var useTargetedClear=true,useTargetedCancel=true,earlyCloseOnDelete=false,authState=true,fresh=true
 var targetAuthorized=true,pasteDispatched=true,attachmentResidual=false
 var inventoryStatus="ok"
 var closeRoute="axclose",raceKey="",raceUsed=false,foreignApp=false
 var globalFocus:Int? { foreignApp ? 3:focus }
 var draft:[Int:Bool]=[:];var selected:Int?=nil;var events:[[String:Any]]=[];var notes:[String:[String]]=[:]
 var closed:[Int]=[];var clears:[Int]=[];var escaped=0,cmdw=0,cmdA=0,delete=0,reopen=0,fullState=0,cacheWrites=0,ipc=0
 var candidateDraft="unresolved",candidateClose="unresolved",lastResolverClosed=false
 func event(_ name:String,_ id:Int=0){ipc += 1;events.append(["kind":name,"id":id])}
 func present(_ id:Int)->Bool{windows.contains{$0.node.id==id}}
 func isLive(_ n:Node)->Bool{present(n.owner) && (n.kind != "input" || inputs[n.owner] === n)}
 func note(_ k:String,_ v:String){notes[k,default:[]].append(v)}
 func close(_ id:Int,via:String){
  if !closeAllowed || sheetOwner==id{return}
  guard present(id) else{return};closed.append(id);windows.removeAll{$0.node.id==id}
  if focus==id{focus=windows.first?.node.id;focusInput=focus.map{$0*10}}
  if inventoryFaultAfterClose{inventoryFault=true}
 }
 func beforeKey(_ key:String){
  event(key)
  if !raceUsed && raceKey==key{raceUsed=true;focus=3;focusInput=30}
 }
 func inventory()->[UIElement]?{
  event("typedWindows")
  guard !inventoryFault && inventoryStatus=="ok" else{return nil}
  if staleInventoryAfterClose && !present(2){return windows+[target]}
  return windows
 }
 func typedPresence(_ target:UIElement)->Int{
  guard let all=inventory() else{return 0};return all.contains{$0.node===target.node} ? 1:2
 }
 func exactFocusedTarget(_ t:UIElement)->Bool{event("typedFocus");return !foreignApp && focus==t.node.id}
 func ownedSheet(_ t:UIElement)->Bool{event("typedSheetOwner");return !foreignApp && sheetOwner==t.node.id && focus==t.node.id}
 func exactFocusedInput(_ i:UIElement,_ t:UIElement)->Bool{event("typedInputOwner");return !foreignApp && i.node.owner==t.node.id && focus==t.node.id && focusInput==i.node.id && present(t.node.id)}
 func targetedClear(_ input:UIElement)->Bool{
  event("AXSetEmpty",input.node.id)
  guard useTargetedClear,isLive(input.node) else{return false}
  draft[input.node.owner]=false;clears.append(input.node.owner)
  event("AXVerifyEmpty",input.node.id);return !draft[input.node.owner,default:true]
 }
 func targetedCancel(_ t:UIElement)->Bool{
  event("AXCancelSheet",t.node.id)
  guard useTargetedCancel,ownedSheet(t),present(t.node.id) else{return false}
  sheetOwner=nil;return true
 }
 func reset(_ scenario:String){
  malformedWindowArray=false;sheetUnknown=false;sheetPersists=false;sheetReplaces=false;newSheetBeforeDelete=false;sheets=[:]
  inputUnderSheet=false;parentUnavailable=false;replacementInput=false;systemInputMismatch=false;valueWrongType=false;valueUnavailable=false;pidFailure=false;inputAppearsAfterEscape=false;composerReplaced=false
  windows=[];inputs=[:];events=[];notes=[:];closed=[];clears=[];draft=[:]
  focus=2;focusInput=20;sheetOwner=nil;raiseFocus=true;inputFocusWorks=true;inputAvailable=true;closeAllowed=true;escapeCloses=true;staleInputReadable=false;inventoryFault=false;inventoryFaultAfterClose=false;staleInventoryAfterClose=false;useTargetedClear=true;useTargetedCancel=true;earlyCloseOnDelete=false;authState=true;fresh=true;closeRoute="axclose";raceKey="";raceUsed=false;foreignApp=false
  targetAuthorized=true;pasteDispatched=true;attachmentResidual=false;inventoryStatus="ok"
  escaped=0;cmdw=0;cmdA=0;delete=0;reopen=0;fullState=0;cacheWrites=0;ipc=0;selected=nil;candidateDraft="unresolved";candidateClose="unresolved"
  for id in [1,2,3]{let n=Node(id,id,"window");n.actions=["AXRaise","AXClose"];windows.append(UIElement(n));inputs[id]=Node(id*10,id,"input");sheets[id]=Node(id*10+2,id,"sheet");draft[id]=true}
  target=windows[1]
  windows.removeAll{$0.node.id==3}
  switch scenario {
  case "normal-owned-sheet","keep-owned-sheet":sheetOwner=2
  case "composer-appears":sheetOwner=2;inputAvailable=false;inputAppearsAfterEscape=true
  case "composer-replaced":sheetOwner=2;composerReplaced=true
  case "caption-first":inputUnderSheet=true;escapeCloses=false
  case "parent-incomplete":parentUnavailable=true;escapeCloses=false
  case "replacement-caption":sheetOwner=2;replacementInput=true
  case "system-input-mismatch":systemInputMismatch=true;escapeCloses=false
  case "value-wrong-type":valueWrongType=true;escapeCloses=false
  case "value-unavailable":valueUnavailable=true;escapeCloses=false
  case "pid-failure":pidFailure=true;escapeCloses=false
  case "sheet-unknown":sheetUnknown=true;escapeCloses=false
  case "sheet-persists":sheetOwner=2;sheetPersists=true
  case "sheet-replaced":sheetOwner=2;sheetReplaces=true
  case "new-sheet-before-delete":escapeCloses=false;newSheetBeforeDelete=true
  case "malformed-window-array":malformedWindowArray=true;escapeCloses=false
  case "pre-verify-failure":escapeCloses=false;targetAuthorized=false;pasteDispatched=false
  case "pre-paste-failure":escapeCloses=false;pasteDispatched=false
  case "paste-uncertain":escapeCloses=false;attachmentResidual=true
  case "attachment-not-text":escapeCloses=false;attachmentResidual=true
  case "external-app-frontmost":escapeCloses=false;foreignApp=true;closeRoute="cmdw";target.node.actions=["AXRaise"]
  case "inventory-no-value","inventory-unsupported","inventory-cannot-complete","inventory-malformed","inventory-wrong-type","inventory-process-changed":inventoryStatus=scenario;escapeCloses=false
  case "normal-no-escape-effect":escapeCloses=false
  case "escape-closes-target":break
  case "stale-input-after-escape":staleInputReadable=true
  case "disappears-after-draft":escapeCloses=false;earlyCloseOnDelete=true
  case "already-absent":windows.removeAll{$0.node.id==2};focus=1;focusInput=10
  case "raise-fails-foreign-focus":raiseFocus=false;inputFocusWorks=false;focus=1;focusInput=10;target.node.actions=[]
  case "draft-focus-fails":escapeCloses=false;raiseFocus=false;inputFocusWorks=false;focus=1;focusInput=10
  case "foreign-sheet":escapeCloses=false;sheetOwner=1;focus=1;focusInput=10;raiseFocus=false;inputFocusWorks=false
  case "unknown-inventory":inventoryFault=true;escapeCloses=false
  case "unknown-after-close":inventoryFaultAfterClose=true;escapeCloses=false
  case "stale-inventory-after-close":staleInventoryAfterClose=true;escapeCloses=false
  case "last-standalone":windows.removeAll{$0.node.id==1};escapeCloses=false
  case "keep-no-sheet":break
  case "keep-focus-fails":escapeCloses=false;inputFocusWorks=false;focus=1;focusInput=10
  case "unsupported-targeted-clear":escapeCloses=false;useTargetedClear=false
  case "unsupported-targeted-cancel":sheetOwner=2;useTargetedCancel=false
  case "missing-input":escapeCloses=false;inputAvailable=false
  case "cache-expired":escapeCloses=false;fresh=false
  case "login-after-reopen":windows.removeAll{$0.node.id==1};escapeCloses=false;authState=false
  case "ack-after-reopen":windows.removeAll{$0.node.id==1};escapeCloses=false;authState=false
  case "race-before-select-all":escapeCloses=false;raceKey="CmdA"
  case "race-before-delete":escapeCloses=false;raceKey="Delete"
  case "race-before-sheet-escape":sheetOwner=2;raceKey="Escape"
  case "blocked-close-no-modal":escapeCloses=false;closeAllowed=false
  case "blocked-close-owned-modal":sheetOwner=2
  case "button-route":escapeCloses=false;closeRoute="button";target.node.actions=["AXRaise"]
  case "command-w-route":escapeCloses=false;closeRoute="cmdw";target.node.actions=["AXRaise"]
  case "race-before-command-w":escapeCloses=false;closeRoute="cmdw";target.node.actions=["AXRaise"];raceKey="CmdW"
  default:break
  }
  if scenario.hasPrefix("race-") || scenario=="external-app-frontmost"{let n=Node(3,3,"window");n.actions=["AXRaise","AXClose"];windows.append(UIElement(n))}
 }
}
let world=World()
func fixtureSleep(forTimeInterval:Double){}
final class NSPasteboard{static let general=NSPasteboard();func clearContents(){world.event("clipboardClear")}}
final class AXActionRunner{
 func log(_ s:String){}
 func waitUntil(label:String,timeout:Double,pollInterval:Double,evaluateAfterTimeout:Bool=true,condition:()->Bool)->Bool{condition()}
 func pressCommandW(){world.beforeKey("CmdW");world.cmdw+=1;if let id=world.globalFocus{world.close(id,via:"CmdW")}}
 func pressEscapeKey(){
  world.beforeKey("Escape");world.escaped+=1
  if let sheet=world.sheetOwner,sheet==world.globalFocus{if !world.sheetPersists{world.sheetOwner=nil};if world.sheetReplaces{world.sheetOwner=1};if world.replacementInput{world.inputs[2]=Node(23,2,"input");world.inputUnderSheet=true};if world.inputAppearsAfterEscape{world.inputAvailable=true};if world.composerReplaced{world.inputs[2]=Node(24,2,"input")};return}
  if world.escapeCloses,let id=world.globalFocus{world.close(id,via:"Escape")}
 }
 func pressCommandA(){world.beforeKey("CmdA");world.cmdA+=1;world.selected=world.globalFocus;if world.newSheetBeforeDelete{world.sheetOwner=1}}
 func pressDeleteKey(){
  world.beforeKey("Delete");world.delete+=1
  if let id=world.globalFocus{world.draft[id]=false;world.clears.append(id)}
  if world.earlyCloseOnDelete{world.close(2,via:"external")}
 }
}
final class PhaseProfiler{func begin(_ s:String){};func end(){};func note(_ k:String,_ v:String){world.note(k,v)}}
final class KakaoTalkApp{
 static var runningApplication:NSRunningApplication?{NSRunningApplication(world.inventoryStatus=="inventory-process-changed" ? 101:100)}
 let applicationElement=UIElement(Node(0,0,"application"))
 var windows:[UIElement]{world.event("windows");if world.inventoryFault{return []};if world.staleInventoryAfterClose && !world.present(2){return world.windows+[world.target]};return world.windows}
 var focusedWindow:UIElement?{world.event("focusedWindow");return world.windows.first{$0.node.id==world.focus}}
 var mainWindow:UIElement?{world.event("mainWindow");return world.windows.first{$0.node.id==1}}
 var hasUsableWindow:Bool{currentUsableWindow() != nil}
 func activate(){world.event("activate")}
 static func forceOpen()->Bool{world.reopen+=1;let n=Node(1,1,"window");world.windows.append(UIElement(n));world.focus=1;world.focusInput=10;return true}
 func waitForUsableWindow(timeout:Double,trace:((String)->Void)?)->UIElement?{currentUsableWindow()}
 // APP
}
final class ChatWindowResolver{
 let kakao=KakaoTalkApp(),runner=AXActionRunner()
 var cleanupApplication:KakaoTalkApp{kakao}
 func note(_ k:String,_ v:String){world.note(k,v)}
 func areSameAXElement(_ a:UIElement,_ b:UIElement)->Bool{a.node===b.node}
 // CLOSE
}
final class UnusedTypedResolver{
 let kakao=KakaoTalkApp(),runner=AXActionRunner()
 func note(_ k:String,_ v:String){world.note(k,v)}
 func areSameAXElement(_ a:UIElement,_ b:UIElement)->Bool{a.node===b.node}
 // TYPED_CLOSE
}
struct ImageCleanup{let keepWindow:Bool
 // IMAGE
}
struct SendCleanup{let keepWindow:Bool
 // SEND
}
