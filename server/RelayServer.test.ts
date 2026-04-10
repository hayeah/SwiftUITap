import { describe, expect, test } from "bun:test";

import { RelayServer } from "./RelayServer";

describe("RelayServer", () => {
  test("routes requests to the targeted device queue", async () => {
    const relay = new RelayServer();

    const pollA = relay.waitForNextRequest("device-a");
    const pollB = relay.waitForNextRequest("device-b");

    const resultA = relay.dispatchRequest("/request", { type: "get", path: "." }, "device-a");
    const resultB = relay.dispatchRequest("/request", { type: "get", path: "." }, "device-b");

    const requestA = await pollA;
    const requestB = await pollB;

    expect(requestA._path).toBe("/request");
    expect(requestB._path).toBe("/request");
    expect(requestA._reqID).not.toBe(requestB._reqID);

    relay.submitResponse("device-a", { _reqID: requestA._reqID, data: "from-a" });
    relay.submitResponse("device-b", { _reqID: requestB._reqID, data: "from-b" });

    await expect(resultA).resolves.toEqual({ _reqID: requestA._reqID, data: "from-a" });
    await expect(resultB).resolves.toEqual({ _reqID: requestB._reqID, data: "from-b" });
  });

  test("defaults untargeted requests to the first connected device", async () => {
    const relay = new RelayServer();

    const pollA = relay.waitForNextRequest("device-a");
    relay.waitForNextRequest("device-b");

    const result = relay.dispatchRequest("/request", { type: "get", path: "todos" }, undefined);
    expect(result).not.toBeNull();

    const request = await pollA;
    expect(request.path).toBe("todos");

    relay.submitResponse("device-a", { _reqID: request._reqID, data: [] });
    await expect(result).resolves.toEqual({ _reqID: request._reqID, data: [] });
  });

  test("queues explicit requests for a device before it connects", async () => {
    const relay = new RelayServer();

    const result = relay.dispatchRequest("/request", { type: "get", path: "todos" }, "device-a");
    expect(result).not.toBeNull();

    const request = await relay.waitForNextRequest("device-a");
    expect(request.path).toBe("todos");

    relay.submitResponse("device-a", { _reqID: request._reqID, data: ["queued"] });
    await expect(result).resolves.toEqual({ _reqID: request._reqID, data: ["queued"] });
  });

  test("rejects untargeted requests when no device has connected", () => {
    const relay = new RelayServer();
    const result = relay.dispatchRequest("/request", { type: "get", path: "." }, undefined);
    expect(result).toBeNull();
  });
});
