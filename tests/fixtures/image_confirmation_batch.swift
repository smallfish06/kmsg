import Foundation
import ApplicationServices.HIServices
let kAXSheetsAttribute="AXSheets"
enum AccessibilityError: Error { case axError(AXError), typeMismatch }
enum KakaoTalkError: Error { case elementNotFound(String), actionFailed(String) }
final class AuthReadDiagnostics {
 enum Kind { case scalar, batch }
 static var current: AuthReadDiagnostics? { nil }
 func beginRead(_ kind:Kind)->UInt64 { 0 }
 func endRead(_ started:UInt64,failed:Bool) {}
 func recordStructure(error:AXError,raw:[AnyObject]?,roleIsString:Bool,childrenAreElements:Bool) {}
}
final class SearchDiscoveryDiagnostics {
 static var currentPass: SearchDiscoveryDiagnostics? { nil }
 func beginRead()->UInt64 { 0 }
 func endRead(_ started:UInt64,batch:Bool,error:AXError) {}
 func recordScalar(element:Node,name:String,error:AXError,raw:CFTypeRef?) {}
 func recordStructure(element:Node,error:AXError,raw:[AnyObject]?) {}
}
enum Clock {
 static var seconds=0.0,sleepSeconds=0.0,scalar=0,batch=0,actions=0
 static func read(_ kind:String,_ node:Int,_ field:String="") {
  seconds += world.cost
  if kind=="batch" {batch += 1} else if kind=="action" {actions += 1} else {scalar += 1}
  world.ipc.append(kind+":"+String(node)+":"+field)
  world.update()
 }
 static func reset(){seconds=0;sleepSeconds=0;scalar=0;batch=0;actions=0}
}
struct Date {let value=Clock.seconds;func timeIntervalSince(_ old:Date)->Double {Clock.seconds-old.value}}
enum Thread {static func sleep(forTimeInterval t:Double){Clock.seconds += t;Clock.sleepSeconds += t;world.update()}}
public final class Node:NSObject {
 let id:Int;var role:String?,title:String?,children:[Node]=[],sheets:AnyObject?=nil
 var live=true,roleFault=false,childrenFault=false,batchFailure=false
 var batchSlots:[String:AnyObject]=[:],sharedSlots:[String:AnyObject]=[:],batchShape=""
 init(_ id:Int,_ role:String?="AXStaticText",_ title:String?=nil){self.id=id;self.role=role;self.title=title}
}
public typealias AXUIElement=Node
func CFEqual(_ a:Node,_ b:Node)->Bool {a===b}
func axError(_ error:AXError)->AnyObject {var value=error;return AXValueCreate(.axError,&value)!}
func scalarValue(_ node:Node,_ name:String)->(AXError,AnyObject?) {
 guard node.live else{return(.invalidUIElement,nil)}
 if let raw=node.sharedSlots[name] {
  if CFGetTypeID(raw)==AXValueGetTypeID(),AXValueGetType(raw as! AXValue) == .axError {
   var error=AXError.success;_ = AXValueGetValue(raw as! AXValue,.axError,&error);return(error,nil)
  }
  return(.success,raw)
 }
 switch name {
 case kAXRoleAttribute:
  if node.roleFault{return(.cannotComplete,nil)}
  return node.role.map{(.success,$0 as NSString)} ?? (.noValue,nil)
 case kAXChildrenAttribute:return node.childrenFault ? (.cannotComplete,nil):(.success,node.children as NSArray)
 case kAXSheetsAttribute:return node.sheets.map{(.success,$0)} ?? (.noValue,nil)
 case kAXTitleAttribute:return node.title.map{(.success,$0 as NSString)} ?? (.noValue,nil)
 default:return(.attributeUnsupported,nil)
 }
}
func AXUIElementCopyAttributeValue(_ node:Node,_ rawName:CFString,_ out:UnsafeMutablePointer<CFTypeRef?>)->AXError {
 let name=rawName as String
 if name==kAXSheetsAttribute {world.beginLookup()}
 Clock.read("scalar",node.id,name)
 let (status,value)=scalarValue(node,name);out.pointee=value;return status
}
func AXUIElementCopyMultipleAttributeValues(_ node:Node,_ names:CFArray,_ options:AXCopyMultipleAttributeOptions,_ out:UnsafeMutablePointer<CFArray?>)->AXError {
 Clock.read("batch",node.id)
 if !node.live{return .invalidUIElement}
 if node.batchFailure{return .cannotComplete}
 if node.batchShape=="unsupported"{return .attributeUnsupported}
 if node.batchShape=="nil"{return .success}
 if node.batchShape=="count"{out.pointee=["synthetic"] as CFArray;return .success}
 let fields=names as! [String]
 let values:[AnyObject]=fields.map { field in
  if let raw=node.batchSlots[field]{return raw}
  let (error,value)=scalarValue(node,field)
  return error == .success ? (value ?? NSNull()):axError(error)
 }
 out.pointee=values as CFArray;return .success
}
func AXUIElementPerformAction(_ node:Node,_ action:CFString)->AXError {
 Clock.read("action",node.id)
 guard node.live else{return .invalidUIElement}
 if world.name=="false-click-unknown-children" {world.root.childrenFault=true;return .cannotComplete}
 if world.name=="false-click-unsent" || world.name.hasPrefix("representative-") {return .cannotComplete}
 world.effects += 1
 if node.id==3002 {world.wrongEffects += 1}
 if world.name=="false-click-retired" {world.retire();return .cannotComplete}
 if world.name=="false-click-still-live" {return .cannotComplete}
 world.retire();return .success
}
public struct UIElement {
 let axElement:Node
 init(_ node:Node){axElement=node}
 // ATTRIBUTE
 // OPTIONAL
 // ROLE
 // TITLE
 // CHILDREN
 // BATCH_PUBLIC
 // BATCH_OBSERVE
 // BATCH_PRIVATE
 // FIRST
 // ALL
 // ALL_ROLE
 // PERFORM
 // PRESS
}
struct AXActionRunner {
 func log(_ value:@autoclosure()->String){}
 // WAIT
 // CLICK
}
struct PhaseProfiler {func begin(_ name:String){};func note(_ name:String,_ value:String){} }
func fixturePrint(_ value:String){}
func hash(_ strings:[String])->String {
 var result:UInt64=1469598103934665603
 for value in strings {for byte in (value+"\n").utf8 {result=(result ^ UInt64(byte)) &* 1099511628211}}
 return String(result,radix:16)
}
final class World {
 var root=Node(0,"AXWindow"),target=Node(2001,kAXSheetRole),other=Node(2002,kAXSheetRole)
 var name="",cost=0.005,ipc:[String]=[],visits:[Int]=[],mutationDone=false,effects=0,wrongEffects=0
 var diagnostics:ImageConfirmationDiagnostics?=nil
 var lookupOrdinal=0
 func beginLookup(){
  guard name.hasPrefix("representative-") else{return}
  lookupOrdinal += 1
  let counts = name.contains("628") ? [200,214,214] : name.contains("649") ? [216,217,216] : [180,185,188]
  let n=counts[min(lookupOrdinal-1,2)]
  let positive=lookupOrdinal==2
  root.children=(1...(n-(positive ? 1:0))).map{Node($0)}
  if name.hasSuffix("-absence") {for node in root.children{node.batchSlots[kAXChildrenAttribute]=axError(.noValue)}}
  if name.hasSuffix("-partial") {for node in root.children where node.id%2==0{node.batchSlots[kAXChildrenAttribute]=axError(.noValue)}}
  if positive{root.children.append(target)}
  root.sheets=nil
 }
 func retire(){target.live=false;for child in target.children{child.live=false};root.children.removeAll{$0===target};root.sheets=[] as NSArray}
 func update(){
  if mutationDone{return}
  if name=="role-retry-late-child" && Clock.seconds>=cost*4 {mutationDone=true;root.children[0].children=[target]}
  if name=="late-sheet" && Clock.seconds>=0.6 {mutationDone=true;root.children.append(target)}
  if name=="retired-sheet" && Clock.seconds>=cost*4 {mutationDone=true;retire()}
  if name=="substitution-before-first" && Clock.seconds>=cost {mutationDone=true;root.children=[other];root.sheets=[other] as NSArray}
  if name=="late-child-between-slots" && Clock.seconds>=cost*4 {mutationDone=true;root.children[0].children=[target]}
  if name=="earlier-role-late" && Clock.seconds>=cost*5 {mutationDone=true;root.children[1].role=kAXSheetRole}
 }
 func reset(_ name:String,_ cost:Double,_ enabled:Bool) {
  self.name=name;self.cost=cost;ipc=[];visits=[];mutationDone=false;effects=0;wrongEffects=0;lookupOrdinal=0
  root=Node(0,"AXWindow");target=Node(2001,kAXSheetRole);other=Node(2002,kAXSheetRole)
  target.children=[Node(3001,kAXButtonRole,"Send")];other.children=[Node(3002,kAXButtonRole,"Send")]
  let count = name=="large-absent" ? 1000 : name=="live-shaped" ? 553:8
  root.children=(1...count).map{Node($0)}
  root.sheets=[] as NSArray
  switch name {
  case "deep-sheet","batch-unsupported","batch-request-error","batch-nil","batch-count","role-error","role-null","role-wrong","child-error","child-null","child-wrong","child-mixed","child-no-value","child-unsupported","role-and-child-error","matching-child-error","matching-role-error","matching-batch-unsupported","raw-role-error","raw-child-error","raw-role-wrong","raw-child-wrong":
   root.children.append(target)
  case "direct-sheet","retired-sheet","stale-direct","false-click-retired","false-click-unsent","false-click-still-live","false-click-unknown-children":root.children.append(target);root.sheets=[target] as NSArray
  case "duplicate-sheets":root.children.insert(other,at:2);root.children.append(target)
  case "nested-bfs-order":root.children[0].children=[target];root.children[1].children=[other]
  case "group-modal":target.role=kAXGroupRole;root.children.append(target)
  case "root-children-error":root.childrenFault=true;root.children.append(target)
  case "direct-unknown":root.sheets=nil
  case "direct-malformed":root.sheets="synthetic-invalid" as NSString
  case "late-child-between-slots":root.children=[Node(1,kAXGroupRole)]
  case "earlier-role-late":root.children=[Node(1),Node(2),target]
  case "substitution-before-first":root.children=[target]
  default:break
  }
  if name=="stale-direct"{target.live=false}
  if (name.hasPrefix("nested-") && name != "nested-bfs-order") || name=="role-retry-late-child" {
   let parent=Node(1,kAXGroupRole);if name != "role-retry-late-child" {parent.children=[target]}
   root.children=[parent]
  }
  let slotName=name.hasPrefix("nested-") ? String(name.dropFirst(7)):name=="role-retry-late-child" ? "role-error":name
  let affected=root.children.filter{$0 !== target}
  for node in affected {
   switch slotName {
   case "batch-unsupported":node.batchShape="unsupported"
   case "batch-request-error":node.batchFailure=true
   case "batch-nil":node.batchShape="nil"
   case "batch-count":node.batchShape="count"
   case "role-error":node.batchSlots[kAXRoleAttribute]=axError(.cannotComplete)
   case "role-null":node.batchSlots[kAXRoleAttribute]=NSNull()
   case "role-wrong":node.batchSlots[kAXRoleAttribute]=NSNumber(value:7)
   case "child-error":node.batchSlots[kAXChildrenAttribute]=axError(.cannotComplete)
   case "child-null":node.batchSlots[kAXChildrenAttribute]=NSNull()
   case "child-wrong":node.batchSlots[kAXChildrenAttribute]="synthetic-invalid" as NSString
   case "child-mixed":node.batchSlots[kAXChildrenAttribute]=[Node(999),"synthetic"] as NSArray
   case "child-no-value":node.batchSlots[kAXChildrenAttribute]=axError(.noValue)
   case "child-unsupported":node.batchSlots[kAXChildrenAttribute]=axError(.attributeUnsupported)
   case "role-and-child-error":node.batchSlots[kAXRoleAttribute]=axError(.invalidUIElement);node.batchSlots[kAXChildrenAttribute]=axError(.cannotComplete)
   case "raw-role-error":node.roleFault=true
   case "raw-child-error":node.childrenFault=true
   case "raw-role-wrong":node.sharedSlots[kAXRoleAttribute]=NSNumber(value:7)
   case "raw-child-wrong":node.sharedSlots[kAXChildrenAttribute]="synthetic-invalid" as NSString
   default:break
   }
  }
  if name=="matching-child-error"{target.batchSlots[kAXChildrenAttribute]=axError(.cannotComplete)}
  if name=="matching-role-error"{target.batchSlots[kAXRoleAttribute]=axError(.cannotComplete)}
  if name=="matching-batch-unsupported"{target.batchShape="unsupported"}
  Clock.reset()
  diagnostics=ImageConfirmationDiagnostics.make(enabled:enabled,now:{UInt64((Clock.seconds*1_000_000_000).rounded())})
 }
}
let world=World()
// COMMANDS
