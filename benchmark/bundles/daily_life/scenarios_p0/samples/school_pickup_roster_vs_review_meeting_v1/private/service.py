#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"signed_in_user":self.fixture["user"],"members":self.state["members"]}
  if op=="roster_list":return {"ok":True,"duties":[d for d in self.state["duties"] if d["date"]==r["date"]]}
  if op=="invitation_list":return {"ok":True,"invitations":[i for i in self.state["invitations"] if not r.get("date") or i["start"][:10]==r["date"]]}
  if op=="invitation_show":
   x=next((i for i in self.state["invitations"] if i["id"]==r["id"]),None);return {"ok":bool(x),"invitation":x,"error":None if x else "invitation_not_found"}
  if op=="roster_reassign":
   d=next((d for d in self.state["duties"] if d["id"]==r["id"] and d["status"]=="assigned"),None)
   if not d:return {"ok":False,"error":"duty_not_found"}
   if not any(m["id"]==r["assignee"] for m in self.state["members"]):return {"ok":False,"error":"member_not_found"}
   before=copy.deepcopy(d);d["assignee"]=r["assignee"];self.audit(uid,"roster.reassign",d["id"],before,d,r.get("reason",""));self.save();return {"ok":True,"duty":d}
  if op=="invitation_accept":
   i=next((i for i in self.state["invitations"] if i["id"]==r["id"] and i["status"]=="pending"),None)
   if not i:return {"ok":False,"error":"invitation_not_pending"}
   before=copy.deepcopy(i);i["status"]="accepted";i["reply"]=r["reply"];self.audit(uid,"invitation.accept",i["id"],before,i);self.save();return {"ok":True,"invitation":i,"warning":"household duties are not changed automatically"}
if __name__=="__main__":serve(ScenarioService)
