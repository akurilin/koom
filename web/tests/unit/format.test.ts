import { describe, expect, it } from "vitest";

import {
  formatBytes,
  formatDate,
  formatDuration,
  formatTimestamp,
} from "@/lib/format";

describe("formatDate", () => {
  it("formats an ISO date string", () => {
    expect(formatDate("2026-03-15T12:00:00Z")).toBe("Mar 15, 2026");
  });

  it("handles midnight UTC", () => {
    expect(formatDate("2026-01-01T00:00:00Z")).toBe("Jan 1, 2026");
  });
});

describe("formatDuration", () => {
  it("formats zero seconds", () => {
    expect(formatDuration(0)).toBe("0:00");
  });

  it("formats seconds only", () => {
    expect(formatDuration(5)).toBe("0:05");
    expect(formatDuration(59)).toBe("0:59");
  });

  it("formats minutes and seconds", () => {
    expect(formatDuration(60)).toBe("1:00");
    expect(formatDuration(61)).toBe("1:01");
    expect(formatDuration(754)).toBe("12:34");
  });

  it("formats hours, minutes, and seconds", () => {
    expect(formatDuration(3600)).toBe("1:00:00");
    expect(formatDuration(3661)).toBe("1:01:01");
    expect(formatDuration(7384)).toBe("2:03:04");
  });

  it("rounds fractional seconds", () => {
    expect(formatDuration(1.4)).toBe("0:01");
    expect(formatDuration(1.5)).toBe("0:02");
  });

  it("clamps negative values to zero", () => {
    expect(formatDuration(-10)).toBe("0:00");
  });
});

describe("formatBytes", () => {
  it("formats bytes", () => {
    expect(formatBytes(0)).toBe("0 B");
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(1023)).toBe("1023 B");
  });

  it("formats kilobytes", () => {
    expect(formatBytes(1024)).toBe("1.0 KB");
    expect(formatBytes(1536)).toBe("1.5 KB");
  });

  it("formats megabytes", () => {
    expect(formatBytes(1024 * 1024)).toBe("1.0 MB");
    expect(formatBytes(5.5 * 1024 * 1024)).toBe("5.5 MB");
  });

  it("formats gigabytes", () => {
    expect(formatBytes(1024 * 1024 * 1024)).toBe("1.00 GB");
    expect(formatBytes(2.5 * 1024 * 1024 * 1024)).toBe("2.50 GB");
  });
});

describe("formatTimestamp", () => {
  it("formats zero", () => {
    expect(formatTimestamp(0)).toBe("0:00");
  });

  it("formats whole seconds", () => {
    expect(formatTimestamp(5)).toBe("0:05");
    expect(formatTimestamp(65)).toBe("1:05");
  });

  it("includes tenths when non-zero", () => {
    expect(formatTimestamp(1.3)).toBe("0:01.3");
    expect(formatTimestamp(62.7)).toBe("1:02.7");
  });

  it("omits tenths when exactly zero", () => {
    expect(formatTimestamp(10.0)).toBe("0:10");
  });

  it("clamps negative values to zero", () => {
    expect(formatTimestamp(-5)).toBe("0:00");
  });

  it("handles sub-second timestamps", () => {
    expect(formatTimestamp(0.5)).toBe("0:00.5");
  });
});
