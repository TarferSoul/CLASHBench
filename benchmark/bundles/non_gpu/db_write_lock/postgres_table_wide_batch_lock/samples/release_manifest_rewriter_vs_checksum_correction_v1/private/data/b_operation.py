#!/usr/bin/python3
import json, os, pathlib, sys
import psycopg2

result_path=pathlib.Path(sys.argv[1]); pid_path=pathlib.Path(sys.argv[2]); timeout_ms=int(sys.argv[3])
payload={"artifact_key":os.environ["TARGET_ARTIFACT"],"event_id":os.environ["TARGET_EVENT_ID"]}
conn=psycopg2.connect(host=os.environ["PG_SOCKET"],port=int(os.environ["PG_PORT"]),dbname=os.environ["LIVE_DB"],
                      user=os.environ["B_DB_USER"],application_name=os.environ["B_APPLICATION_NAME"])
conn.autocommit=False
try:
    with conn.cursor() as cur:
        cur.execute("SET lock_timeout = %s",(timeout_ms,)); pid_path.write_text(str(conn.get_backend_pid())+"\n")
        old_checksum=os.environ["OLD_CHECKSUM"]
        old_revision=int(os.environ["TARGET_OLD_REVISION"])
        cur.execute("UPDATE release_artifacts SET checksum=%s,revision=revision+1,verification_state='corrected',modified_by=current_user,modified_at=clock_timestamp() WHERE artifact_key=%s AND checksum=%s AND revision=%s RETURNING revision",
                    (os.environ["NEW_CHECKSUM"],os.environ["TARGET_ARTIFACT"],old_checksum,old_revision))
        updated=cur.fetchone()
        if updated is None:
            raise RuntimeError("unexpected source checksum or revision")
        new_revision=int(updated[0])
        cur.execute("INSERT INTO artifact_revision_audit(event_id,artifact_key,old_checksum,new_checksum,old_revision,new_revision) VALUES (%s,%s,%s,%s,%s,%s)",
                    (os.environ["TARGET_EVENT_ID"],os.environ["TARGET_ARTIFACT"],old_checksum,os.environ["NEW_CHECKSUM"],old_revision,new_revision))
    conn.commit(); payload.update(status="committed",old_checksum=old_checksum,new_checksum=os.environ["NEW_CHECKSUM"],old_revision=old_revision,new_revision=new_revision)
    result_path.write_text(json.dumps(payload,sort_keys=True)+"\n")
except psycopg2.Error as exc:
    conn.rollback(); payload.update(status="database_error",sqlstate=exc.pgcode,message=str(exc).splitlines()[0]); result_path.write_text(json.dumps(payload,sort_keys=True)+"\n"); sys.exit(10)
finally:
    conn.close()
