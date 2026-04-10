export const DEVICE_UDID_HEADER = "x-swiftui-tap-udid";

const DEFAULT_DEVICE_KEY = "__default__";
const DEVICE_STALE_MS = 30_000;

interface PendingRequest {
  _reqID: string;
  request: any;
  resolve: (body: any) => void;
  delivered: boolean;
}

interface DeviceState {
  key: string;
  queue: PendingRequest[];
  waiting: ((request: any) => void) | null;
  createdAt: number;
  lastSeenAt: number | null;
}

export class RelayServer {
  private readonly devices = new Map<string, DeviceState>();
  private requestCounter = 0;

  submitResponse(deviceUDID: string | null | undefined, body: any) {
    if (!body?._reqID) {
      return;
    }

    const preferredDevice = this.devices.get(this.normalizeDeviceKey(deviceUDID));
    const device =
      preferredDevice && preferredDevice.queue.some((entry) => entry._reqID === body._reqID)
        ? preferredDevice
        : Array.from(this.devices.values()).find((entry) =>
            entry.queue.some((pending) => pending._reqID === body._reqID)
          );

    if (!device) {
      return;
    }

    const idx = device.queue.findIndex((entry) => entry._reqID === body._reqID);
    if (idx < 0) {
      return;
    }

    const pending = device.queue.splice(idx, 1)[0];
    pending.resolve(body);
  }

  waitForNextRequest(deviceUDID: string | null | undefined): Promise<any> {
    const device = this.getOrCreateDevice(deviceUDID, true);
    const next = device.queue.find((entry) => !entry.delivered);

    if (next) {
      next.delivered = true;
      return Promise.resolve(next.request);
    }

    return new Promise<any>((resolve) => {
      device.waiting = (request: any) => {
        device.waiting = null;
        resolve(request);
      };
    });
  }

  dispatchRequest(
    path: string,
    request: any,
    targetUDID: string | null | undefined
  ): Promise<any> | null {
    const targetKey = this.resolveTargetDeviceKey(targetUDID);
    if (!targetKey) {
      return null;
    }

    request._reqID = `req_${++this.requestCounter}`;
    request._path = path;
    return this.deliverToDevice(targetKey, request);
  }

  health() {
    const devices = Array.from(this.devices.values()).map((device) => ({
      udid: device.key === DEFAULT_DEVICE_KEY ? null : device.key,
      connected: this.isConnected(device),
      pendingRequests: device.queue.length,
      waiting: device.waiting !== null,
      lastSeenAt: device.lastSeenAt,
    }));

    return {
      status: "ok",
      appConnected: devices.some((device) => device.connected),
      pendingRequests: devices.reduce((sum, device) => sum + device.pendingRequests, 0),
      devices,
    };
  }

  private deliverToDevice(deviceKey: string, request: any): Promise<any> {
    const device = this.getOrCreateDevice(deviceKey, false);

    return new Promise<any>((resolve) => {
      const entry: PendingRequest = {
        _reqID: request._reqID,
        request,
        resolve,
        delivered: false,
      };
      device.queue.push(entry);

      if (device.waiting) {
        const deliver = device.waiting;
        device.waiting = null;
        entry.delivered = true;
        deliver(request);
      }
    });
  }

  private resolveTargetDeviceKey(targetUDID: string | null | undefined): string | null {
    const trimmedTarget = this.trimmedValue(targetUDID);
    if (trimmedTarget) {
      return this.normalizeDeviceKey(trimmedTarget);
    }

    for (const device of this.devices.values()) {
      if (this.isConnected(device)) {
        return device.key;
      }
    }

    return null;
  }

  private getOrCreateDevice(
    deviceUDID: string | null | undefined,
    markSeen: boolean
  ): DeviceState {
    const key = this.normalizeDeviceKey(deviceUDID);
    let device = this.devices.get(key);
    if (!device) {
      const now = Date.now();
      device = {
        key,
        queue: [],
        waiting: null,
        createdAt: now,
        lastSeenAt: markSeen ? now : null,
      };
      this.devices.set(key, device);
    } else if (markSeen) {
      device.lastSeenAt = Date.now();
    }

    return device;
  }

  private normalizeDeviceKey(deviceUDID: string | null | undefined): string {
    return this.trimmedValue(deviceUDID) ?? DEFAULT_DEVICE_KEY;
  }

  private trimmedValue(value: string | null | undefined): string | null {
    const trimmed = value?.trim();
    return trimmed ? trimmed : null;
  }

  private isConnected(device: DeviceState): boolean {
    if (device.waiting) {
      return true;
    }

    if (device.lastSeenAt == null) {
      return false;
    }

    return Date.now() - device.lastSeenAt < DEVICE_STALE_MS;
  }
}
