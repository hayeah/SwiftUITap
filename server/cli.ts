#!/usr/bin/env bun

import { DEVICE_UDID_HEADER } from "./RelayServer";

/**
 * swiftui-tap — CLI for SwiftUITap
 *
 * Usage:
 *   swiftui-tap [--udid <udid>] server [--port 9876] [--debug]
 *   swiftui-tap [--udid <udid>] view tree [id] [--json]
 *   swiftui-tap [--udid <udid>] view screenshot [id] [-o file] [--format png|jpg] [--scale N]
 *   swiftui-tap [--udid <udid>] state get <path>
 *   swiftui-tap [--udid <udid>] state set <path> <value>
 *   swiftui-tap [--udid <udid>] state call <method> [key=value ...]
 *   swiftui-tap [--udid <udid>] eval [tag] <code>
 *   swiftui-tap [--udid <udid>] eval [tag] --module <file.ts>
 *
 * Env: SWIFTUI_TAP_URL (default: http://localhost:9876)
 *      SWIFTUI_TAP_UDID (optional target device)
 */

const BASE_URL = process.env.SWIFTUI_TAP_URL || "http://localhost:9876";
const TARGET_UDID = parseTargetUDID(process.argv.slice(2));

// --- HTTP helpers ---

async function postJSON(path: string, body: any, timeout = 30000): Promise<any> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const resp = await fetch(`${BASE_URL}${path}`, {
      method: "POST",
      headers: buildHeaders(),
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    return await resp.json();
  } finally {
    clearTimeout(timer);
  }
}

function buildHeaders(): Record<string, string> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };

  if (TARGET_UDID) {
    headers[DEVICE_UDID_HEADER] = TARGET_UDID;
  }

  return headers;
}

function parseTargetUDID(argv: string[]): string | undefined {
  const cliValue = readOption(argv, "--udid");
  const envValue = process.env.SWIFTUI_TAP_UDID;
  const target = cliValue ?? envValue;
  return target?.trim() || undefined;
}

function readOption(argv: string[], flag: string): string | undefined {
  const index = argv.indexOf(flag);
  if (index < 0) {
    return undefined;
  }

  const value = argv[index + 1];
  if (!value || value.startsWith("-")) {
    console.error(`Missing value for ${flag}`);
    process.exit(1);
  }

  return value;
}

function stripGlobalOptions(argv: string[]): string[] {
  const stripped: string[] = [];

  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--udid") {
      i += 1;
      continue;
    }

    stripped.push(argv[i]);
  }

  return stripped;
}

function requestState(payload: any) {
  return postJSON("/request", payload);
}

function requestView(payload: any, timeout = 60000) {
  return postJSON("/view", payload, timeout);
}

// --- Tree formatting ---

function roundRect(r: any) {
  if (!r) return r;
  const rd = (n: number) => Math.round(n * 10) / 10;
  return { x: rd(r.x), y: rd(r.y), w: rd(r.w), h: rd(r.h) };
}

function normalizeTree(node: any): any {
  if (!node) return node;
  if (Array.isArray(node)) {
    return node
      .map(normalizeTree)
      .sort((a, b) => (a.frame?.y ?? 0) - (b.frame?.y ?? 0));
  }
  const rd = (n: number | null) => (n != null ? Math.round(n * 10) / 10 : null);
  const out: any = { id: node.id };
  if (node.frame) out.frame = roundRect(node.frame);
  if (node.relativeFrame) out.relativeFrame = roundRect(node.relativeFrame);
  if (node.proposed)
    out.proposed = { w: rd(node.proposed.w), h: rd(node.proposed.h) };
  if (node.reported)
    out.reported = { w: rd(node.reported.w), h: rd(node.reported.h) };
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

function fmtRect(r: any): string {
  return `(${r.x},${r.y} ${r.w}x${r.h})`;
}

function fmtSize(s: any): string {
  const w = s.w != null ? s.w : "?";
  const h = s.h != null ? s.h : "?";
  return `${w}x${h}`;
}

function treeToText(node: any, indent = 0, isLast = true, prefix = ""): string {
  const lines: string[] = [];

  const connector =
    indent === 0 ? "" : isLast ? "└─ " : "├─ ";

  const f = node.frame;
  const frameStr = f ? fmtRect(f) : "";
  lines.push(`${prefix}${connector}${node.id}  ${frameStr}`);

  const childPrefix =
    prefix + (isLast || indent === 0 ? "   " : "│  ");

  const parts: string[] = [];
  if (node.relativeFrame) parts.push(`rel=(${node.relativeFrame.x},${node.relativeFrame.y})`);
  if (node.proposed) parts.push(`proposed=${fmtSize(node.proposed)}`);
  if (node.reported) parts.push(`reported=${fmtSize(node.reported)}`);
  if (parts.length) lines.push(`${childPrefix}  ${parts.join("  ")}`);

  const children = node.children || [];
  for (let i = 0; i < children.length; i++) {
    lines.push(treeToText(children[i], indent + 1, i === children.length - 1, childPrefix));
  }

  return lines.join("\n");
}

// --- Value parsing ---

function parseValue(raw: string): any {
  try {
    return JSON.parse(raw);
  } catch {
    return raw;
  }
}

// --- Commands ---

async function cmdServer(args: string[]) {
  // Just exec the server
  const serverArgs = ["run", `${import.meta.dir}/index.ts`, ...args];
  const proc = Bun.spawn(["bun", ...serverArgs], {
    stdio: ["inherit", "inherit", "inherit"],
  });
  await proc.exited;
}

async function cmdViewTree(args: string[]) {
  let id: string | undefined;
  let jsonOutput = false;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--json" || args[i] === "-j") jsonOutput = true;
    else if (!args[i].startsWith("-")) id = args[i];
  }

  const payload: any = { type: "tree" };
  if (id) payload.id = id;

  const result = await requestView(payload);
  if (result.error) {
    console.error("Error:", result.error);
    process.exit(1);
  }

  const data = normalizeTree(result.data);

  if (jsonOutput) {
    console.log(JSON.stringify(data, null, 2));
  } else {
    if (Array.isArray(data)) {
      for (const root of data) console.log(treeToText(root));
    } else {
      console.log(treeToText(data));
    }
  }
}

async function cmdViewScreenshot(args: string[]) {
  let id: string | undefined;
  let output: string | undefined;
  let format = "png";
  let quality = 0.8;
  let scale: number | undefined;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "-o" || args[i] === "--output") output = args[++i];
    else if (args[i] === "-f" || args[i] === "--format") format = args[++i];
    else if (args[i] === "-q" || args[i] === "--quality") quality = parseFloat(args[++i]);
    else if (args[i] === "-s" || args[i] === "--scale") scale = parseFloat(args[++i]);
    else if (!args[i].startsWith("-")) id = args[i];
  }

  const payload: any = { type: "screenshot" };
  if (id) payload.id = id;
  if (format !== "png") payload.format = format;
  if (quality !== 0.8) payload.quality = quality;
  if (scale != null) payload.scale = scale;

  const result = await requestView(payload, 60000);
  if (result.error) {
    console.error("Error:", result.error);
    process.exit(1);
  }

  const data = result.data;
  const imageBytes = Buffer.from(data.image, "base64");
  const ext = data.format === "jpg" || data.format === "jpeg" ? "jpg" : "png";

  if (!output) {
    const suffix = id ? id.replace(/\./g, "_") : "full";
    output = `screenshot_${suffix}.${ext}`;
  }

  await Bun.write(output, imageBytes);
  const size = data.size || {};
  console.log(
    `Saved ${output} (${size.w}x${size.h} ${data.format}, ${imageBytes.length} bytes)`
  );
}

async function cmdStateGet(args: string[]) {
  const path = args[0] || ".";
  const raw = args.includes("--raw") || args.includes("-r");

  // Parse --depth N
  let depth: number | undefined;
  const depthIdx = args.indexOf("--depth");
  if (depthIdx >= 0 && args[depthIdx + 1]) {
    depth = parseInt(args[depthIdx + 1], 10);
  }

  const payload: any = { type: "get", path };
  if (depth !== undefined) payload.depth = depth;

  const result = await requestState(payload);
  if (result.error) {
    console.error("Error:", result.error);
    process.exit(1);
  }

  console.log(JSON.stringify(result.data, null, 2));
}

async function cmdStateSet(args: string[]) {
  const path = args[0];
  const value = parseValue(args[1]);

  if (!path || args[1] === undefined) {
    console.error("Usage: swiftui-tap state set <path> <value>");
    process.exit(1);
  }

  const result = await requestState({ type: "set", path, value });
  if (result.error) {
    console.error("Error:", result.error);
    process.exit(1);
  }

  console.log(`OK set ${path} = ${JSON.stringify(value)}`);
}

async function cmdStateCall(args: string[]) {
  const method = args[0];
  if (!method) {
    console.error("Usage: swiftui-tap state call <method> [json]");
    process.exit(1);
  }

  let params: any = {};
  if (args.length > 1) {
    const json = args.slice(1).join(" ");
    try {
      params = JSON.parse(json);
    } catch {
      console.error(`Invalid JSON: ${json}`);
      process.exit(1);
    }
  }

  const result = await requestState({ type: "call", method, params });
  if (result.error) {
    console.error("Error:", result.error);
    process.exit(1);
  }

  if (result.data != null) {
    console.log(JSON.stringify(result.data, null, 2));
  } else {
    console.log("OK");
  }
}

// --- KIF touch commands ---

async function cmdKIFTap(args: string[]) {
  const x = parseFloat(args[0]);
  const y = parseFloat(args[1]);
  if (isNaN(x) || isNaN(y)) {
    console.error("Usage: swiftui-tap kif.tap <x> <y>");
    process.exit(1);
  }
  const result = await requestState({ type: "call", method: ".kif.tap", params: { x, y } });
  if (result.error) { console.error("Error:", result.error); process.exit(1); }
  console.log("OK tap", x, y);
}

async function cmdKIFSwipe(args: string[]) {
  const x1 = parseFloat(args[0]);
  const y1 = parseFloat(args[1]);
  const x2 = parseFloat(args[2]);
  const y2 = parseFloat(args[3]);
  const duration = args[4] ? parseFloat(args[4]) : 0.3;
  if (isNaN(x1) || isNaN(y1) || isNaN(x2) || isNaN(y2)) {
    console.error("Usage: swiftui-tap kif.swipe <x1> <y1> <x2> <y2> [duration]");
    process.exit(1);
  }
  const result = await requestState({ type: "call", method: ".kif.swipe", params: { x1, y1, x2, y2, duration } });
  if (result.error) { console.error("Error:", result.error); process.exit(1); }
  console.log("OK swipe", x1, y1, "->", x2, y2);
}

async function cmdKIFLongPress(args: string[]) {
  const x = parseFloat(args[0]);
  const y = parseFloat(args[1]);
  const duration = args[2] ? parseFloat(args[2]) : 1.0;
  if (isNaN(x) || isNaN(y)) {
    console.error("Usage: swiftui-tap kif.longpress <x> <y> [duration]");
    process.exit(1);
  }
  const result = await requestState({ type: "call", method: ".kif.longpress", params: { x, y, duration } });
  if (result.error) { console.error("Error:", result.error); process.exit(1); }
  console.log("OK longpress", x, y, "for", duration, "s");
}

async function cmdKIFType(args: string[]) {
  const text = args.join(" ");
  if (!text) {
    console.error("Usage: swiftui-tap kif.type <text>");
    process.exit(1);
  }
  const result = await requestState({ type: "call", method: ".kif.type", params: { text } });
  if (result.error) { console.error("Error:", result.error); process.exit(1); }
  console.log("OK typed", JSON.stringify(text));
}

// --- Eval commands ---

async function cmdEval(args: string[]) {
  let tag: string | undefined;
  let code: string | undefined;
  let moduleFile: string | undefined;

  // Parse args: eval [tag] <code> OR eval [tag] --module <file.ts>
  const moduleIdx = args.indexOf("--module");
  if (moduleIdx >= 0) {
    moduleFile = args[moduleIdx + 1];
    if (!moduleFile) {
      console.error("Usage: swiftui-tap eval [tag] --module <file.ts>");
      process.exit(1);
    }
    // Everything before --module that isn't a flag is the tag
    const preArgs = args.slice(0, moduleIdx).filter((a) => !a.startsWith("-"));
    tag = preArgs[0];
  } else {
    // eval [tag] <code>
    // If there's only one non-flag arg, it's the code (no tag)
    // If there are two+, first is tag, rest is code
    const nonFlagArgs: string[] = [];
    for (const a of args) {
      if (!a.startsWith("-")) nonFlagArgs.push(a);
    }

    if (nonFlagArgs.length === 0) {
      console.error(
        "Usage: swiftui-tap eval [tag] <code>\n       swiftui-tap eval [tag] --module <file.ts>"
      );
      process.exit(1);
    } else if (nonFlagArgs.length === 1) {
      code = nonFlagArgs[0];
    } else {
      tag = nonFlagArgs[0];
      code = nonFlagArgs.slice(1).join(" ");
    }
  }

  // If --module, bundle the file via bun build
  if (moduleFile) {
    code = await bundleModule(moduleFile);
  }

  if (!code) {
    console.error("No code to evaluate");
    process.exit(1);
  }

  const payload: any = { type: "eval", code };
  if (tag) payload.tag = tag;

  const result = await requestState(payload);
  if (result.error) {
    console.error("Error:", result.error);
    process.exit(1);
  }

  if (result.data != null) {
    console.log(JSON.stringify(result.data, null, 2));
  } else {
    console.log("null");
  }
}

async function bundleModule(filePath: string): Promise<string> {
  // Use bun build CLI with IIFE format so the bundle is eval-safe
  const proc = Bun.spawn(
    ["bun", "build", filePath, "--target", "browser", "--format", "iife", "--global-name", "__tap_module__"],
    { stdout: "pipe", stderr: "pipe" }
  );

  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);

  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    console.error("Bundle failed:", stderr || stdout);
    process.exit(1);
  }

  // The IIFE assigns to __tap_module__. Call its default export.
  return `${stdout}
;(async () => {
  const mod = __tap_module__;
  const def = mod.default || mod;
  return typeof def === 'function' ? def() : def;
})()`;
}

// --- Main ---

const args = stripGlobalOptions(process.argv.slice(2));
const cmd = args[0];
const sub = args[1];
const rest = args.slice(2);

if (cmd === "server") {
  await cmdServer(rest);
} else if (cmd === "view" && sub === "tree") {
  await cmdViewTree(rest);
} else if (cmd === "view" && sub === "screenshot") {
  await cmdViewScreenshot(rest);
} else if (cmd === "state" && sub === "get") {
  await cmdStateGet(rest);
} else if (cmd === "state" && sub === "set") {
  await cmdStateSet(rest);
} else if (cmd === "state" && sub === "call") {
  await cmdStateCall(rest);
} else if (cmd === "eval") {
  await cmdEval(args.slice(1));
} else if (cmd === "kif.tap") {
  await cmdKIFTap(args.slice(1));
} else if (cmd === "kif.swipe") {
  await cmdKIFSwipe(args.slice(1));
} else if (cmd === "kif.longpress") {
  await cmdKIFLongPress(args.slice(1));
} else if (cmd === "kif.type") {
  await cmdKIFType(args.slice(1));
} else {
  console.log(`swiftui-tap — CLI for SwiftUITap

Usage:
  swiftui-tap [--udid <udid>] server [--port 9876] [--debug]
  swiftui-tap [--udid <udid>] view tree [id] [--json]
  swiftui-tap [--udid <udid>] view screenshot [id] [-o file] [--format png|jpg] [--scale N]
  swiftui-tap [--udid <udid>] state get <path>
  swiftui-tap [--udid <udid>] state set <path> <value>
  swiftui-tap [--udid <udid>] state call <method> [key=value ...]
  swiftui-tap [--udid <udid>] eval [tag] <code>
  swiftui-tap [--udid <udid>] eval [tag] --module <file.ts>
  swiftui-tap [--udid <udid>] kif.tap <x> <y>
  swiftui-tap [--udid <udid>] kif.swipe <x1> <y1> <x2> <y2> [duration]
  swiftui-tap [--udid <udid>] kif.longpress <x> <y> [duration]
  swiftui-tap [--udid <udid>] kif.type <text>

Env:
  SWIFTUI_TAP_URL   default: http://localhost:9876
  SWIFTUI_TAP_UDID  optional target device`);
}
