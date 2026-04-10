#!/usr/bin/env bun

import { DEVICE_UDID_HEADER, RelayServer } from "./RelayServer";

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

const relayServer = new RelayServer();

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

// Normalize a tree node: round numbers, sort children, consistent property order.
// Returns a new object (does not mutate in place).
function normalizeTree(node: any): any {
  if (!node) return node;

  if (Array.isArray(node)) {
    return node
      .map(normalizeTree)
      .sort((a: any, b: any) => (a.frame?.y ?? 0) - (b.frame?.y ?? 0));
  }

  // Rebuild with consistent property order
  const out: any = { id: node.id };

  if (node.frame) out.frame = roundRect(node.frame);
  if (node.relativeFrame) out.relativeFrame = roundRect(node.relativeFrame);

  if (node.proposed) {
    out.proposed = {
      w: node.proposed.w != null ? round1(node.proposed.w) : null,
      h: node.proposed.h != null ? round1(node.proposed.h) : null,
    };
  }
  if (node.reported) {
    out.reported = {
      w: round1(node.reported.w),
      h: round1(node.reported.h),
    };
  }

  if (node.children) {
    out.children = node.children
      .map(normalizeTree)
      .sort((a: any, b: any) => {
        const dy = (a.frame?.y ?? 0) - (b.frame?.y ?? 0);
        if (Math.abs(dy) > 1) return dy;
        return (a.frame?.x ?? 0) - (b.frame?.x ?? 0);
      });
  }

  return out;
}

Bun.serve({
  port,

  async fetch(req) {
    const url = new URL(req.url);
    const udid = req.headers.get(DEVICE_UDID_HEADER) ?? url.searchParams.get("udid");

    if (url.pathname === "/poll" && req.method === "POST") {
      const body = await req.json().catch(() => null);
      relayServer.submitResponse(udid, body);
      if (body?._reqID) {
        log("← app response for", body._reqID, "udid=", udid ?? "(default)", JSON.stringify(body));
      }

      const nextRequest = await relayServer.waitForNextRequest(udid);
      log("→ delivering request to app", nextRequest._reqID, "udid=", udid ?? "(default)");
      return Response.json(nextRequest);
    }

    if (
      (url.pathname === "/request" || url.pathname === "/view") &&
      req.method === "POST"
    ) {
      const request = await req.json();
      const resultPromise = relayServer.dispatchRequest(url.pathname, request, udid);
      if (!resultPromise) {
        return Response.json({ error: "no app connected" }, { status: 503 });
      }

      log("← agent request", request._reqID, url.pathname, "udid=", udid ?? "(default)", JSON.stringify(request));

      const result = await resultPromise;

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

      // Post-process tree: sort siblings by y, round numbers, consistent key order
      if (
        url.pathname === "/view" &&
        request.type === "tree" &&
        result.data
      ) {
        result.data = normalizeTree(result.data);
      }

      // Strip internal fields from the response
      const { _reqID, _path, ...cleanResult } = result;
      log("→ agent response", request._reqID, JSON.stringify(cleanResult));
      return Response.json(cleanResult);
    }

    if (url.pathname === "/health") {
      return Response.json(relayServer.health());
    }

    return new Response("not found", { status: 404 });
  },
});

console.log(`[agentsdk-server] listening on http://localhost:${port}`);
