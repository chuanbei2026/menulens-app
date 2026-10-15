// Structured logging. One JSON object per line on stdout, so CloudWatch Logs Insights can query
// every field directly. Request lines also carry CloudWatch Embedded Metric Format (EMF) metadata:
// CloudWatch turns them into metrics in the "ForeignMenu" namespace without any API calls.
//
// Privacy: never log menu text, photos, prompts, model output, tokens or secrets. Only metadata.

const NAMESPACE = "ForeignMenu";

function emit(line) {
  // Written raw (not console.log) so each line stays pure JSON, which EMF requires.
  process.stdout.write(`${JSON.stringify(line)}\n`);
}

/** Non-request events: grants, settlement problems, unexpected errors. */
export function logEvent(level, msg, fields = {}) {
  emit({ time: new Date().toISOString(), level, msg, ...fields });
}

/**
 * The single summary line for one HTTP request, plus metrics.
 * Fields: requestId, route, status, ms, userId?, error?, ddb* (calls, time, capacity, conditional
 * failures, errors, ops per command), and for /chat: model (upstream id), modelId (our id), requestedModel?,
 * routedFrom?/fallbackFrom? + routeReason? (the picked model when another answered), costUsd, ttfbMs, inputTokens, cachedTokens, outputTokens,
 * creditsCharged, creditsReserved, creditsLeft (credits with one decimal), upstreamStatus, grant?, nickname? (the user's display
 * name, for the top-users table), images?/imageChars? (counts only)
 */
export function logRequest(r) {
  const status = r.status ?? 500;
  const metrics = {
    Requests: 1,
    ServerErrors: status >= 500 ? 1 : 0,
    ClientErrors: status >= 400 && status < 500 ? 1 : 0,
    LatencyMs: r.ms,
  };
  // Usage metrics only exist for model calls; leaving them out elsewhere keeps averages honest.
  if (typeof r.inputTokens === "number") {
    Object.assign(metrics, { InputTokens: r.inputTokens, CachedTokens: r.cachedTokens ?? 0, OutputTokens: r.outputTokens });
  }
  if (typeof r.creditsCharged === "number") metrics.CreditsCharged = r.creditsCharged;
  if (typeof r.ttfbMs === "number") metrics.TimeToFirstByteMs = r.ttfbMs;
  if (r.grant) metrics[r.grant === "signup" ? "Signups" : "MonthlyGrants"] = 1;
  if (typeof r.ddbCalls === "number") {
    Object.assign(metrics, { DdbCalls: r.ddbCalls, DdbMs: r.ddbMs, DdbCapacityUnits: r.ddbCapacityUnits,
                             DdbConditionalFailures: r.ddbConditionalFailures, DdbErrors: r.ddbErrors });
  }

  const units = { LatencyMs: "Milliseconds", TimeToFirstByteMs: "Milliseconds", DdbMs: "Milliseconds" };
  emit({
    time: new Date().toISOString(),
    level: status >= 500 ? "ERROR" : status >= 400 ? "WARN" : "INFO",
    msg: "request",
    ...r,
    status,
    ...metrics,
    _aws: {
      Timestamp: Date.now(),
      CloudWatchMetrics: [{
        Namespace: NAMESPACE,
        Dimensions: [["route"], []], // per route, and an all-routes total
        Metrics: Object.keys(metrics).map((Name) => ({ Name, Unit: units[Name] ?? "Count" })),
      }],
    },
  });
}
