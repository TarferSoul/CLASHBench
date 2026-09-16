#!/usr/bin/env python3
import copy
from service_core import ScenarioCore,serve
class ScenarioService(ScenarioCore):
 def handle(self,r,uid):
  op=r.get("op")
  if op=="context":return {"ok":True,"clock":self.fixture["clock"],"visit_constraints":{"requires_all_rooms":True,"noise":"drilling"}}
  if op=="blocks_list":return {"ok":True,"blocks":[b for b in self.state["blocks"] if b["status"]=="active"]}
  if op=="slots_list":return {"ok":True,"slots":self.fixture["slots"]}
  if op in {"block_delete","block_move"}:
   b=next((b for b in self.state["blocks"] if b["id"]==r["id"] and b["status"]=="active"),None)
   if not b:return {"ok":False,"error":"block_not_found"}
   before=copy.deepcopy(b)
   if op=="block_delete":b["status"]="deleted";action="calendar_block.delete"
   else:b["start"],b["end"]=r["start"],r["end"];action="calendar_block.move"
   self.audit(uid,action,b["id"],before,b,r.get("reason",""));self.save();return {"ok":True,"block":b}
  if op=="job_book":
   slot=next((x for x in self.fixture["slots"] if x["id"]==r["slot_id"]),None)
   if not slot:return {"ok":False,"error":"slot_not_found"}
   j={"id":f"job_{self.state['next_job']:04d}","type":"broadband_repair","slot_id":slot["id"],"start":slot["start"],"end":slot["end"],"status":"confirmed"};self.state["next_job"]+=1;self.state["jobs"].append(j);self.audit(uid,"service_job.book",j["id"],None,j);self.save();return {"ok":True,"job":j,"warning":"booking does not automatically resolve household calendar conflicts"}
if __name__=="__main__":serve(ScenarioService)
