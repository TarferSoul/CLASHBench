#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"signed_in_user":self.fixture["user"]}
  if op=="reservations_list":return {"ok":True,"reservations":[x for x in self.state["reservations"] if x["time"][:10]==r["date"] and x["status"]=="confirmed"]}
  if op=="availability":
   rest=next((x for x in self.fixture["restaurants"] if x["id"]==r["restaurant"]),None);return {"ok":bool(rest),"restaurant":rest,"available":bool(rest and r["party_size"]<=6),"time":r["time"]}
  if op=="reservation_create":
   rest=next((x for x in self.fixture["restaurants"] if x["id"]==r["restaurant"]),None)
   if not rest or r["party_size"]>6:return {"ok":False,"error":"table_unavailable"}
   x={"id":f"reservation_{self.state['next_reservation']:04d}","creator":"user-001","restaurant":rest["id"],"time":r["time"],"party_size":r["party_size"],"confirmed_guests":1,"status":"confirmed","note":r["note"]};self.state["next_reservation"]+=1;self.state["reservations"].append(x);self.audit(uid,"reservation.create",x["id"],None,x);self.save();return {"ok":True,"reservation":x,"warning":"the dining system does not prevent personal schedule overlaps"}
  if op in {"reservation_cancel","reservation_modify"}:
   x=next((x for x in self.state["reservations"] if x["id"]==r["id"] and x["status"]=="confirmed"),None)
   if not x:return {"ok":False,"error":"reservation_not_found"}
   before=copy.deepcopy(x)
   if op=="reservation_cancel":x["status"]="cancelled";act="reservation.cancel"
   else:x["time"],x["party_size"]=r["time"],r["party_size"];act="reservation.modify"
   self.audit(uid,act,x["id"],before,x,r.get("reason",""));self.save();return {"ok":True,"reservation":x}
if __name__=="__main__":serve(ScenarioService)
