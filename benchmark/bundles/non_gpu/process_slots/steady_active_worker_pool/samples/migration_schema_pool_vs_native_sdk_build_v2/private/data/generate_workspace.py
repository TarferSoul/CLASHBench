#!/usr/bin/env python3
import pathlib
import sys


def write(path, content, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(mode)


def main():
    migration_root = pathlib.Path(sys.argv[1])
    migration_workers = int(sys.argv[2])
    sdk_root = pathlib.Path(sys.argv[3])
    sdk_workers = int(sys.argv[4])
    for worker in range(migration_workers):
        tenant = migration_root / f"tenant-{worker:02d}"
        write(tenant / "001_core.sql", f"""\
create table tenant_config(
  tenant_id integer primary key,
  schema_lane text not null unique
);
insert into tenant_config values ({worker + 1}, 'lane-{worker:02d}');
create table accounts(
  account_id integer primary key,
  name text not null
);
create table audit_events(
  event_id integer primary key,
  account_id integer not null references accounts(account_id),
  payload text not null
);
""")
        write(tenant / "002_indexes.sql", """\
create index audit_events_account_idx on audit_events(account_id);
create view account_event_counts as
select a.account_id, a.name, count(e.event_id) as event_count
from accounts a left join audit_events e on e.account_id = a.account_id
group by a.account_id, a.name;
""")
        write(tenant / "003_guards.sql", """\
create trigger audit_payload_required
before insert on audit_events
when length(new.payload) = 0
begin
  select raise(abort, 'audit payload required');
end;
""")
    declarations = [f"int telemetry_unit_{unit:02d}(const telemetry_frame *frame);" for unit in range(sdk_workers)]
    write(sdk_root / "include" / "telemetry_sdk.h", """\
#ifndef TELEMETRY_SDK_H
#define TELEMETRY_SDK_H
#include <stddef.h>
#include <stdint.h>
typedef struct {
  const uint8_t *data;
  size_t length;
  uint32_t stream_id;
} telemetry_frame;
""" + "\n".join(declarations) + "\n#endif\n")
    for unit in range(sdk_workers):
        write(sdk_root / "src" / f"unit_{unit:02d}.c", f"""\
#include "telemetry_sdk.h"

int telemetry_unit_{unit:02d}(const telemetry_frame *frame) {{
  uint32_t checksum = frame->stream_id ^ {unit + 17}u;
  size_t index;
  if (frame == 0 || frame->data == 0) return -1;
  for (index = 0; index < frame->length; ++index) {{
    checksum = (checksum * 16777619u) ^ frame->data[index];
  }}
  return (int)(checksum & 0x7fffffffU);
}}
""")


if __name__ == "__main__":
    main()
