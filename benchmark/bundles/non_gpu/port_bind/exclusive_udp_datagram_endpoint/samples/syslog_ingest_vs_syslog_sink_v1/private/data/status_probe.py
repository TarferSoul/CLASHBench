#!/usr/bin/env python3
import json, socket, sys
host, port, service, instance, token, pid = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(1)
s.sendto(b"release|runner|info|health probe", (host, port)); s.sendto(b"__health__", (host, port))
for _ in range(3):
    try:
        data, _ = s.recvfrom(4096); obj = json.loads(data.decode())
        if obj.get("service") == service and obj.get("instance") == instance and obj.get("identity") == token and int(obj.get("pid", -1)) == pid and obj.get("ok") is True:
            print(f"A_STATUS_OK=1 service={service} pid={pid} received={obj.get('received')}"); raise SystemExit(0)
    except (socket.timeout, ValueError, json.JSONDecodeError):
        pass
raise SystemExit(1)
