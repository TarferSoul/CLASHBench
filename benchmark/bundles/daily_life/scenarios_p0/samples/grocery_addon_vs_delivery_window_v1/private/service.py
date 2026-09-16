#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"signed_in_user":self.fixture["user"],"windows":self.fixture["windows"]}
  if op=="orders_list":return {"ok":True,"orders":[o for o in self.state["orders"] if o["status"]=="confirmed"]}
  if op=="order_show":
   o=next((o for o in self.state["orders"] if o["id"]==r["id"]),None);return {"ok":bool(o),"order":o,"window":self.fixture["windows"].get(o["window"]) if o else None,"error":None if o else "order_not_found"}
  if op=="inventory_check":return {"ok":True,"item":r["item"],"window":r["window"],"available":r["item"] in self.fixture["availability"].get(r["window"],[])}
  if op=="order_add":
   o=next((o for o in self.state["orders"] if o["id"]==r["id"] and o["status"]=="confirmed"),None)
   if not o:return {"ok":False,"error":"order_not_found"}
   missing=[x for x in r["items"] if x not in self.fixture["availability"][o["window"]]]
   if missing:self.audit(uid,"order.add_rejected",o["id"],None,r,"items_unavailable_for_window",{"available_window":"thu-1000"});self.save();return {"ok":False,"error":"items_unavailable_for_window","items":missing,"available_window":"thu-1000"}
   before=copy.deepcopy(o)
   for x in r["items"]:o["items"].append({"id":x,"quantity":1})
   self.audit(uid,"order.items.add",o["id"],before,o);self.save();return {"ok":True,"order":o}
  if op=="order_change_window":
   o=next((o for o in self.state["orders"] if o["id"]==r["id"] and o["status"]=="confirmed"),None)
   if not o:return {"ok":False,"error":"order_not_found"}
   if any(x["id"] not in self.fixture["availability"].get(r["window"],[]) for x in o["items"]):return {"ok":False,"error":"existing_item_unavailable"}
   before=copy.deepcopy(o);o["window"]=r["window"];self.audit(uid,"order.window.change",o["id"],before,o,r.get("reason",""));self.save();return {"ok":True,"order":o,"window":self.fixture["windows"][o["window"]]}
if __name__=="__main__":serve(ScenarioService)
