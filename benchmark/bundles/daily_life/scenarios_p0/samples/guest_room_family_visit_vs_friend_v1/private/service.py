#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"guest_room_capacity":1}
  if op=="blocks_list":return {"ok":True,"blocks":[b for b in self.state["room_blocks"] if b["status"]=="active"]}
  if op=="restaurants_search":return {"ok":True,"restaurants":self.fixture["restaurants"],"time":r["time"]}
  if op in {"block_delete","block_modify"}:
   b=next((b for b in self.state["room_blocks"] if b["id"]==r["id"] and b["status"]=="active"),None)
   if not b:return {"ok":False,"error":"block_not_found"}
   before=copy.deepcopy(b)
   if op=="block_delete":b["status"]="deleted";action="room_block.delete"
   else:b["start"],b["end"]=r["start"],r["end"];action="room_block.modify"
   self.audit(uid,action,b["id"],before,b,r.get("reason",""));self.save();return {"ok":True,"block":b}
  if op=="room_assign":
   conflicts=[b for b in self.state["room_blocks"] if b["status"]=="active" and b["start"]<=r["date"]<b["end"]]
   if conflicts:return {"ok":False,"error":"guest_room_occupied","conflicts":[b["id"] for b in conflicts]}
   x={"id":f"lodging_{self.state['next_lodging']:04d}","guest":r["guest"],"kind":"guest_room","date":r["date"],"status":"confirmed","price":0};self.state["next_lodging"]+=1;self.state["lodgings"].append(x);self.audit(uid,"guest_room.assign",x["id"],None,x);self.save();return {"ok":True,"lodging":x}
  if op=="dinner_book":
   rest=next((x for x in self.fixture["restaurants"] if x["id"]==r["restaurant_id"] and x["available"]==r["time"]),None)
   if not rest:return {"ok":False,"error":"table_unavailable"}
   d={"id":f"dinner_{self.state['next_dinner']:04d}","restaurant_id":rest["id"],"time":r["time"],"party_size":2,"status":"confirmed"};self.state["next_dinner"]+=1;self.state["dinners"].append(d);self.audit(uid,"dinner.book",d["id"],None,d);self.save();return {"ok":True,"dinner":d}
if __name__=="__main__":serve(ScenarioService)
