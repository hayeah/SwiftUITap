#!/usr/bin/env bun

// Minimal HTTP server that pairs agent requests with app long-polls.
//
// - POST /poll    — app long-polls here; receives queued requests, responds with results
// - POST /request — agent sends a command, blocks until the app responds
//
// Usage: bun run server/index.ts --port 9876

const args = Bun.argv;
const portIdx = args.indexOf("--port");
const port = portIdx >= 0 ? parseInt(args[portIdx + 1]) : 9876;
const debug = args.includes("--debug");

function log(...msg: any[]) {
  if (debug) console.log("[agentsdk]", ...msg);
}

// Pending agent requests waiting for app responses
interface PendingRequest {
  id: string;
  request: any;
  resolve: (body: any) => void;
}

const pendingRequests: PendingRequest[] = [];
let requestCounter = 0;

// App poll — resolves when there's a request to process
let appWaiting: ((request: any) => void) | null = null;

function deliverToApp(request: any): Promise<any> {
  return new Promise<any>((resolve) => {
    const entry: PendingRequest = {
      id: request.id,
      request,
      resolve,
    };
    pendingRequests.push(entry);

    // If app is already waiting, deliver immediately
    if (appWaiting) {
      const deliver = appWaiting;
      appWaiting = null;
      deliver(request);
    }
  });
}

Bun.serve({
  port,

  async fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/poll" && req.method === "POST") {
      const body = await req.json().catch(() => null);

      // If body has an id, it's a response to a previous request
      if (body?.id) {
        const idx = pendingRequests.findIndex((p) => p.id === body.id);
        if (idx >= 0) {
          const pending = pendingRequests.splice(idx, 1)[0];
          log("← app response for", body.id, JSON.stringify(body));
          pending.resolve(body);
        }
      }

      // Wait for the next agent request
      if (pendingRequests.length > 0) {
        // There's already a queued request — return it immediately
        const next = pendingRequests.find(
          (p) => !("delivered" in (p as any))
        );
        if (next) {
          (next as any).delivered = true;
          log("→ delivering queued request", next.id);
          return Response.json(next.request);
        }
      }

      // No queued requests — wait
      return new Promise<Response>((resolve) => {
        appWaiting = (request: any) => {
          log("→ delivering request to app", request.id);
          resolve(Response.json(request));
        };
      });
    }

    if (url.pathname === "/request" && req.method === "POST") {
      const request = await req.json();
      request.id = request.id || `req_${++requestCounter}`;

      log("← agent request", request.id, JSON.stringify(request));

      if (!appWaiting && pendingRequests.length === 0) {
        // No app connected — we'll queue it and wait
        log("  (no app connected, queueing)");
      }

      const result = await deliverToApp(request);
      log("→ agent response", request.id, JSON.stringify(result));
      return Response.json(result);
    }

    if (url.pathname === "/health") {
      return Response.json({
        status: "ok",
        appConnected: appWaiting !== null,
        pendingRequests: pendingRequests.length,
      });
    }

    return new Response("not found", { status: 404 });
  },
});

console.log(`[agentsdk-server] listening on http://localhost:${port}`);
