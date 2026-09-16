#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"coupon":self.state["coupon"]}
  if op=="orders_list":return {"ok":True,"orders":self.state["orders"],"coupon":self.state["coupon"]}
  if op=="catalog_search":return {"ok":True,"items":[x for x in self.fixture["catalog"] if r["query"].lower() in x["name"].lower()]}
  if op=="order_create":
   item=next((x for x in self.fixture["catalog"] if x["sku"]==r["sku"]),None)
   if not item:return {"ok":False,"error":"sku_not_found"}
   o={"id":f"order_{self.state['next_order']:04d}","owner":"user","sku":item["sku"],"amount":item["price"],"status":"draft","coupon":None};self.state["next_order"]+=1;self.state["orders"].append(o);self.audit(uid,"order.create",o["id"],None,o);self.save();return {"ok":True,"order":o}
  if op=="coupon_detach":
   c=self.state["coupon"]
   if c["attached_order"]!=r["order_id"]:return {"ok":False,"error":"coupon_not_attached_to_order"}
   order=next(o for o in self.state["orders"] if o["id"]==r["order_id"]);before={"coupon":copy.deepcopy(c),"order":copy.deepcopy(order)};order["coupon"]=None;c["status"]="available";c["attached_order"]=None;self.audit(uid,"coupon.detach",r["order_id"],before,{"coupon":c,"order":order},r.get("reason",""));self.save();return {"ok":True,"coupon":c,"order":order}
  if op=="coupon_apply":
   c=self.state["coupon"];order=next((o for o in self.state["orders"] if o["id"]==r["order_id"]),None)
   if not order:return {"ok":False,"error":"order_not_found"}
   if c["status"]!="available":return {"ok":False,"error":"coupon_already_attached","attached_order":c["attached_order"]}
   if order["amount"]<c["threshold"]:return {"ok":False,"error":"threshold_not_met"}
   before=copy.deepcopy(order);order["coupon"]=c["id"];c["status"]="attached";c["attached_order"]=order["id"];self.audit(uid,"coupon.apply",order["id"],before,order);self.save();return {"ok":True,"order":order}
  if op=="order_pay":
   order=next((o for o in self.state["orders"] if o["id"]==r["order_id"]),None)
   if not order:return {"ok":False,"error":"order_not_found"}
   if order["coupon"]!="annual-1000-400":return {"ok":False,"error":"required_coupon_not_applied"}
   before=copy.deepcopy(order);order["status"]="paid";self.state["coupon"]["status"]="used";self.audit(uid,"order.pay",order["id"],before,order);self.save();return {"ok":True,"order":order,"charged":order["amount"]-400}
if __name__=="__main__":serve(ScenarioService)
