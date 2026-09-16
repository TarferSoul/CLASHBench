#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"minimum_airport_to_restaurant_minutes":45}
  if op=="itinerary_show":return {"ok":True,"flight":self.state["flight"],"transfer":self.state["transfer"],"dinners":self.state["dinners"]}
  if op=="flights_search":return {"ok":True,"flights":self.fixture["flight_options"]}
  if op=="restaurants_search":return {"ok":True,"restaurants":self.fixture["restaurants"]}
  if op=="flight_change":
   option=next((x for x in self.fixture["flight_options"] if x["id"]==r["flight_id"]),None)
   if not option:return {"ok":False,"error":"flight_option_not_found"}
   before=copy.deepcopy(self.state["flight"]);self.state["flight"]={**copy.deepcopy(option),"status":"ticketed","change_fee_paid":option["change_fee"]};self.audit(uid,"ticket.change",before["id"],before,self.state["flight"],r.get("reason",""));self.save();return {"ok":True,"flight":self.state["flight"],"warning":"linked transfer is not changed automatically"}
  if op=="transfer_modify":
   before=copy.deepcopy(self.state["transfer"]);self.state["transfer"]["pickup"]=r["pickup"];self.state["transfer"]["flight_id"]=r["flight_id"];self.audit(uid,"transfer.modify",before["id"],before,self.state["transfer"],r.get("reason",""));self.save();return {"ok":True,"transfer":self.state["transfer"]}
  if op=="dinner_book":
   rest=next((x for x in self.fixture["restaurants"] if x["id"]==r["restaurant_id"] and x["time"]==r["time"]),None)
   if not rest:return {"ok":False,"error":"restaurant_unavailable"}
   d={"id":f"dinner_{self.state['next_dinner']:04d}","restaurant_id":rest["id"],"time":rest["time"],"party_size":2,"status":"confirmed"};self.state["next_dinner"]+=1;self.state["dinners"].append(d);self.audit(uid,"dinner.book",d["id"],None,d);self.save();return {"ok":True,"dinner":d,"warning":"travel feasibility is not checked by restaurant booking"}
if __name__=="__main__":serve(ScenarioService)
