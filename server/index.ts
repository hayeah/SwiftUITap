#!/usr/bin/env bun

// Minimal HTTP server that pairs agent requests with app long-polls.
//
// - POST /poll    — app long-polls here; receives queued requests, responds with results
// - POST /request — agent sends a state command (get/set/call), blocks until the app responds
// - POST /view    — agent sends a view command (tree/screenshot/get/set/call), blocks until the app responds
//
// Usage: bun run server/index.ts --port 9876

const args = Bun.argv;
const portIdx = args.indexOf("--port");
const port = portIdx >= 0 ? parseInt(args[portIdx + 1]) : 9876;
const debug = args.includes("--debug");

function log(...msg: any[]) {
  if (debug) console.log("[agentsdk]", ...msg);
}

// Pending agent requests waiting for app responses.
// Uses _reqID (internal) for tracking — never touches user-facing fields like "id".
interface PendingRequest {
  _reqID: string;
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
      _reqID: request._reqID,
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

// Process screenshot: crop to view id frame, resize, convert format
async function processScreenshot(
  data: any,
  request: any
): Promise<any> {
  let { image, format, size, scale, frames } = data;
  const targetID = request.id; // user's view id, not _reqID
  const requestedFormat = request.format || "png";
  const requestedQuality = request.quality ?? 0.8;
  const requestedScale = request.scale;

  // If a view ID was specified and we have frames, crop
  if (targetID && frames && frames[targetID]) {
    const frame = frames[targetID];
    const nativeScale = scale || 1;

    // Crop coordinates are in points — multiply by scale for pixels
    const cropX = Math.round(frame.x * nativeScale);
    const cropY = Math.round(frame.y * nativeScale);
    const cropW = Math.round(frame.w * nativeScale);
    const cropH = Math.round(frame.h * nativeScale);

    // Decode base64 PNG, crop, re-encode
    const buf = Buffer.from(image, "base64");

    try {
      const sharp = require("sharp");
      let pipeline = sharp(buf).extract({
        left: cropX,
        top: cropY,
        width: cropW,
        height: cropH,
      });

      // Rescale if requested
      if (requestedScale && requestedScale !== nativeScale) {
        const ratio = requestedScale / nativeScale;
        pipeline = pipeline.resize(
          Math.round(cropW * ratio),
          Math.round(cropH * ratio)
        );
      }

      // Format conversion
      if (requestedFormat === "jpg" || requestedFormat === "jpeg") {
        pipeline = pipeline.jpeg({
          quality: Math.round(requestedQuality * 100),
        });
        format = "jpg";
      } else {
        pipeline = pipeline.png();
        format = "png";
      }

      const outputBuf = await pipeline.toBuffer();
      return {
        image: outputBuf.toString("base64"),
        format,
        size: { w: frame.w, h: frame.h },
        scale: requestedScale || nativeScale,
      };
    } catch (e: any) {
      // sharp not available — return uncropped with a warning
      return {
        ...data,
        warning: `crop failed: ${e.message}. Install sharp for image processing.`,
      };
    }
  }

  // No cropping needed — return as-is
  return data;
}

// Round a number to 1 decimal place
function round1(n: number): number {
  return Math.round(n * 10) / 10;
}

// Round all numeric values in a rect object
function roundRect(rect: any): any {
  if (!rect) return rect;
  return {
    x: round1(rect.x),
    y: round1(rect.y),
    w: round1(rect.w),
    h: round1(rect.h),
  };
}

// Normalize a tree node: round numbers, sort children by y then x
function normalizeTree(node: any): void {
  if (!node) return;

  // Handle array of roots
  if (Array.isArray(node)) {
    node.forEach(normalizeTree);
    node.sort((a: any, b: any) => (a.frame?.y ?? 0) - (b.frame?.y ?? 0));
    return;
  }

  if (node.frame) node.frame = roundRect(node.frame);
  if (node.relativeFrame) node.relativeFrame = roundRect(node.relativeFrame);
  if (node.proposed) {
    node.proposed = {
      w: node.proposed.w != null ? round1(node.proposed.w) : null,
      h: node.proposed.h != null ? round1(node.proposed.h) : null,
    };
  }
  if (node.reported) {
    node.reported = {
      w: round1(node.reported.w),
      h: round1(node.reported.h),
    };
  }

  if (node.children) {
    node.children.forEach(normalizeTree);
    // Sort siblings: top to bottom, then left to right
    node.children.sort((a: any, b: any) => {
      const dy = (a.frame?.y ?? 0) - (b.frame?.y ?? 0);
      if (Math.abs(dy) > 1) return dy;
      return (a.frame?.x ?? 0) - (b.frame?.x ?? 0);
    });
  }
}

Bun.serve({
  port,

  async fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/poll" && req.method === "POST") {
      const body = await req.json().catch(() => null);

      // If body has a _reqID, it's a response to a previous request
      if (body?._reqID) {
        const idx = pendingRequests.findIndex(
          (p) => p._reqID === body._reqID
        );
        if (idx >= 0) {
          const pending = pendingRequests.splice(idx, 1)[0];
          log("← app response for", body._reqID, JSON.stringify(body));
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
          log("→ delivering queued request", next._reqID);
          return Response.json(next.request);
        }
      }

      // No queued requests — wait
      return new Promise<Response>((resolve) => {
        appWaiting = (request: any) => {
          log("→ delivering request to app", request._reqID);
          resolve(Response.json(request));
        };
      });
    }

    if (
      (url.pathname === "/request" || url.pathname === "/view") &&
      req.method === "POST"
    ) {
      const request = await req.json();
      request._reqID = `req_${++requestCounter}`;
      request._path = url.pathname;

      log(
        "← agent request",
        request._reqID,
        url.pathname,
        JSON.stringify(request)
      );

      if (!appWaiting && pendingRequests.length === 0) {
        log("  (no app connected, queueing)");
      }

      const result = await deliverToApp(request);

      // Post-process screenshot: crop to view id if specified
      if (
        url.pathname === "/view" &&
        request.type === "screenshot" &&
        result.data?.image &&
        request.id
      ) {
        const processed = await processScreenshot(result.data, request);
        log("→ agent response", request._reqID, "(screenshot processed)");
        return Response.json({ data: processed });
      }

      // Post-process tree: sort siblings by y, round numbers
      if (
        url.pathname === "/view" &&
        request.type === "tree" &&
        result.data
      ) {
        normalizeTree(result.data);
      }

      // Strip internal fields from the response
      const { _reqID, _path, ...cleanResult } = result;
      log("→ agent response", request._reqID, JSON.stringify(cleanResult));
      return Response.json(cleanResult);
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
