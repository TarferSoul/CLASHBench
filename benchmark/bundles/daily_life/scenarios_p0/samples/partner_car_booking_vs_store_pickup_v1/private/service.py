#!/usr/bin/env python3
import copy
from service_core import ScenarioCore, serve
def ov(a,b,c,d): return a<d and c<b
class ScenarioService(ScenarioCore):
    def handle(self,r,uid):
        op=r.get("op")
        if op=="context": return {"ok":True,"clock":self.fixture["clock"],"signed_in_user":self.fixture["user"]}
        if op=="vehicle_schedule": return {"ok":True,"vehicle":self.state["vehicle"],"bookings":[b for b in self.state["bookings"] if b["status"]=="active" and b["start"][:10]==r["date"]]}
        if op=="pickup_slots": return {"ok":True,"slots":[s for s in self.state["pickup_slots"] if s["start"][:10]==r["date"]]}
        if op in {"booking_cancel","booking_move"}:
            b=next((x for x in self.state["bookings"] if x["id"]==r["id"] and x["status"]=="active"),None)
            if not b:return {"ok":False,"error":"booking_not_found"}
            before=copy.deepcopy(b)
            if op=="booking_cancel": b["status"]="cancelled"; action="vehicle_booking.cancel"
            else: b["start"],b["end"]=r["start"],r["end"]; action="vehicle_booking.move"
            self.audit(uid,action,b["id"],before,b,r.get("reason",""));self.save();return {"ok":True,"booking":b}
        if op=="pickup_reserve":
            slot=next((s for s in self.state["pickup_slots"] if s["id"]==r["slot_id"] and s["available"]),None)
            if not slot:return {"ok":False,"error":"pickup_slot_unavailable"}
            pickup={"id":f"pickup_{self.state['next_pickup']:04d}","slot_id":slot["id"],"start":slot["start"],"end":slot["end"],"status":"reserved"};self.state["next_pickup"]+=1;slot["available"]=False;self.state["pickups"].append(pickup);self.audit(uid,"pickup.reserve",pickup["id"],None,pickup);self.save();return {"ok":True,"pickup":pickup}
        if op=="transport_plan":
            pickup=next((p for p in self.state["pickups"] if p["id"]==r["pickup_id"] and p["status"]=="reserved"),None)
            if not pickup:return {"ok":False,"error":"pickup_not_found"}
            if r["mode"]!="family-car":return {"ok":False,"error":"unsupported_transport_mode","supported_modes":["family-car"]}
            blockers=[b for b in self.state["bookings"] if b["status"]=="active" and ov(b["start"],b["end"],r["start"],r["end"])]
            if blockers:self.audit(uid,"transport.plan_rejected",pickup["id"],None,r,"vehicle_unavailable");self.save();return {"ok":False,"error":"vehicle_unavailable","blockers":blockers}
            plan={"id":"transport_"+pickup["id"],"pickup_id":pickup["id"],"mode":"family-car","start":r["start"],"end":r["end"],"status":"confirmed","quoted_cost_cny":0};self.state["transport_plans"].append(plan);self.audit(uid,"transport.plan",plan["id"],None,plan);self.save();return {"ok":True,"plan":plan}
if __name__=="__main__":serve(ScenarioService)
