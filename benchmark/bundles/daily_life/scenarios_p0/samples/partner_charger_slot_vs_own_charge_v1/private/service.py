#!/usr/bin/env python3
import copy
from datetime import datetime
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"charger":self.fixture["charger"],"vehicles":self.fixture["vehicles"],"available_until":self.fixture["available_until"]}
  if op=="reservations_list":return {"ok":True,"reservations":[x for x in self.state["reservations"] if x["status"]=="active"]}
  if op in {"reservation_delete","reservation_shorten"}:
   x=next((x for x in self.state["reservations"] if x["id"]==r["id"] and x["status"]=="active"),None)
   if not x:return {"ok":False,"error":"reservation_not_found"}
   before=copy.deepcopy(x)
   if op=="reservation_delete":x["status"]="deleted";action="charging_slot.delete"
   else:x["end"]=r["end"];action="charging_slot.shorten"
   self.audit(uid,action,x["id"],before,x,r.get("reason",""));self.save();return {"ok":True,"reservation":x}
  if op=="reservation_create":
   start,end=datetime.fromisoformat(r["start"]),datetime.fromisoformat(r["end"])
   if end>datetime.fromisoformat(self.fixture["available_until"]) or end<=start:return {"ok":False,"error":"invalid_window"}
   conflicts=[x for x in self.state["reservations"] if x["status"]=="active" and datetime.fromisoformat(x["start"])<end and start<datetime.fromisoformat(x["end"])]
   if conflicts:return {"ok":False,"error":"charger_occupied","conflicts":[x["id"] for x in conflicts]}
   v=next((v for v in self.fixture["vehicles"] if v["id"]==r["vehicle"]),None)
   if not v:return {"ok":False,"error":"vehicle_not_found"}
   energy=(end-start).total_seconds()/3600*self.fixture["charger"]["power_kw"];needed=(r["target"]-v["state_of_charge"])/100*v["battery_kwh"]
   if energy<needed:return {"ok":False,"error":"insufficient_duration","energy_kwh":energy,"needed_kwh":needed}
   x={"id":f"charge_{self.state['next_reservation']:04d}","vehicle":v["id"],"start":r["start"],"end":r["end"],"target":r["target"],"status":"active","purpose":"Reach requested charge"};self.state["next_reservation"]+=1;self.state["reservations"].append(x);self.audit(uid,"charging_slot.create",x["id"],None,x);self.save();return {"ok":True,"reservation":x,"estimated_energy_kwh":energy}
if __name__=="__main__":serve(ScenarioService)
