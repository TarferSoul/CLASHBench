#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"guardian":self.fixture["user"],"drivers":self.state["drivers"],"route_minutes_between_sites":40}
  if op=="lessons_list":return {"ok":True,"lessons":[x for x in self.state["lessons"] if x["start"][:10]==r["date"]]}
  if op=="classes_list":return {"ok":True,"classes":[x for x in self.state["classes"] if x["level"]==r["level"]]}
  if op in {"lesson_skip","lesson_cancel"}:
   x=next((x for x in self.state["lessons"] if x["id"]==r["id"] and x["status"]=="confirmed"),None)
   if not x:return {"ok":False,"error":"lesson_not_active"}
   before=copy.deepcopy(x);x["status"]="skipped" if op=="lesson_skip" else "cancelled";act="lesson.skip" if op=="lesson_skip" else "lesson.cancel";self.audit(uid,act,x["id"],before,x,r.get("reason",""),{"refund":False});self.save();return {"ok":True,"lesson":x,"refund":False}
  if op=="class_enroll":
   c=next((c for c in self.state["classes"] if c["id"]==r["class_id"] and c["available"]),None)
   if not c:return {"ok":False,"error":"class_unavailable"}
   e={"id":f"enrollment_{self.state['next_enrollment']:04d}","class_id":c["id"],"child_id":r["child_id"],"status":"enrolled"};self.state["next_enrollment"]+=1;c["available"]=False;self.state["enrollments"].append(e);self.audit(uid,"class.enroll",e["id"],None,e);self.save();return {"ok":True,"enrollment":e}
  if op=="transport_assign":
   e=next((e for e in self.state["enrollments"] if e["id"]==r["enrollment_id"]),None);c=next((c for c in self.state["classes"] if e and c["id"]==e["class_id"]),None)
   if not e:return {"ok":False,"error":"enrollment_not_found"}
   conflicts=[l for l in self.state["lessons"] if l["status"]=="confirmed" and l["driver"]==r["driver"] and l["start"]<c["end"] and c["start"]<l["end"]]
   if conflicts:self.audit(uid,"transport.assign_rejected",e["id"],None,r,"route_conflict");self.save();return {"ok":False,"error":"driver_route_conflict","conflicts":conflicts,"travel_minutes":40}
   t={"id":"transport_"+e["id"],"enrollment_id":e["id"],"driver":r["driver"],"status":"assigned"};self.state["transport"].append(t);self.audit(uid,"transport.assign",t["id"],None,t);self.save();return {"ok":True,"transport":t}
if __name__=="__main__":serve(ScenarioService)
