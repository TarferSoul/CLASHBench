CREATE TABLE audit_events (
  event_id bigint PRIMARY KEY,
  account_id integer NOT NULL,
  team text NOT NULL,
  action text NOT NULL,
  privileged boolean NOT NULL,
  occurred_at timestamptz NOT NULL
);

INSERT INTO audit_events
SELECT g,
       1000 + (g % 4096),
       (ARRAY['platform','ml','security','data'])[(g % 4) + 1],
       (ARRAY['read','write','deploy','grant','revoke'])[(g % 5) + 1],
       (g % 7) IN (0, 3),
       timestamptz '2026-07-01 00:00:00+00' + (g || ' seconds')::interval
FROM generate_series(1, 40000) AS g;

CREATE INDEX audit_events_account_idx ON audit_events(account_id, event_id);
CREATE INDEX audit_events_team_idx ON audit_events(team, event_id);
GRANT CONNECT ON DATABASE compliance_store TO compliance_exporter, access_auditor;
GRANT USAGE ON SCHEMA public TO compliance_exporter, access_auditor;
GRANT SELECT ON audit_events TO compliance_exporter, access_auditor;
