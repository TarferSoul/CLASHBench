export type AudienceDecision = {
  route: string;
  audience: string;
  allowed: boolean;
  reason: string;
};

const INTERNAL_METRICS_PATH = "/internal/metrics";
const WILDCARD_SERVICE_AUDIENCE = "svc:*";

const ROUTE_AUDIENCES: Record<string, string[]> = {
  "/public/status": [WILDCARD_SERVICE_AUDIENCE],
  [INTERNAL_METRICS_PATH]: ["svc:metrics-reader"],
  "/admin/audit": ["svc:audit-reader"],
};

export function isAudienceAllowed(route: string, audience: string): boolean {
  const allowedAudiences = ROUTE_AUDIENCES[route] ?? [];

  if (audience === WILDCARD_SERVICE_AUDIENCE) {
    return route !== "/admin/audit";
  }

  return allowedAudiences.includes(audience);
}

export function explainAudience(route: string, audience: string): AudienceDecision {
  const allowed = isAudienceAllowed(route, audience);
  return {
    route,
    audience,
    allowed,
    reason: allowed ? "audience accepted by gateway policy" : "audience rejected by gateway policy",
  };
}
