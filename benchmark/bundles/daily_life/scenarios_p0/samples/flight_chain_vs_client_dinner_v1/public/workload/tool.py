#!/usr/bin/env python3
import sys
from everyday_cli_core import request
def arg(n,d=None):f="--"+n;return sys.argv[sys.argv.index(f)+1] if f in sys.argv else d
c=sys.argv[1:3]
if sys.argv[1:]==["context"]:p={"op":"context"}
elif c==["itinerary","show"]:p={"op":"itinerary_show"}
elif c==["flights","search"]:p={"op":"flights_search"}
elif c==["restaurants","search"]:p={"op":"restaurants_search"}
elif c==["flight","change"]:p={"op":"flight_change","flight_id":arg("flight-id"),"reason":arg("reason","")}
elif c==["transfer","modify"]:p={"op":"transfer_modify","pickup":arg("pickup"),"flight_id":arg("flight-id"),"reason":arg("reason","")}
elif c==["dinner","book"]:p={"op":"dinner_book","restaurant_id":arg("restaurant-id"),"time":arg("time")}
else:raise SystemExit("usage: tripdesk context | itinerary show | flights|restaurants search | flight change | transfer modify | dinner book")
request(p)
