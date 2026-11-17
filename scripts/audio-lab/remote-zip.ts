/*
 * Reads individual entries out of a large remote .zip with HTTP range
 * requests, so the lab can take a few clips from a multi-hundred-MB
 * dataset archive without downloading all of it. Supports the stored and
 * deflate methods and ZIP64 sizes/offsets, which covers dataset zips.
 */

import { inflateRawSync } from "node:zlib";

// Zenodo rejects Node's default fetch User-Agent with a 403.
const USER_AGENT = "koom-audio-lab/1.0";

export interface RemoteZipEntry {
  name: string;
  method: number;
  compressedSize: number;
  uncompressedSize: number;
  localHeaderOffset: number;
}

async function fetchRange(
  url: string,
  start: number,
  endInclusive: number,
): Promise<Buffer> {
  const response = await fetch(url, {
    headers: {
      Range: `bytes=${start}-${endInclusive}`,
      "User-Agent": USER_AGENT,
    },
  });
  if (response.status !== 206) {
    throw new Error(
      `range request to ${url} returned ${response.status}, not 206`,
    );
  }
  return Buffer.from(await response.arrayBuffer());
}

async function contentLength(url: string): Promise<number> {
  // A one-byte range request reports the total size in Content-Range and
  // follows the release-asset redirect like any other GET.
  const response = await fetch(url, {
    headers: { Range: "bytes=0-0", "User-Agent": USER_AGENT },
  });
  const range = response.headers.get("content-range");
  const total = range?.split("/")[1];
  await response.arrayBuffer();
  if (!total || total === "*") {
    throw new Error(
      `${url} did not report a Content-Range total (HTTP ${response.status})`,
    );
  }
  return Number(total);
}

function readUInt64(buffer: Buffer, offset: number): number {
  return Number(buffer.readBigUInt64LE(offset));
}

export async function listRemoteZip(url: string): Promise<RemoteZipEntry[]> {
  const size = await contentLength(url);
  const tailLength = Math.min(size, 128 * 1024);
  const tail = await fetchRange(url, size - tailLength, size - 1);

  const eocd = tail.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
  if (eocd < 0) throw new Error(`${url}: end of central directory not found`);
  let entryCount = tail.readUInt16LE(eocd + 10);
  let directorySize = tail.readUInt32LE(eocd + 12);
  let directoryOffset = tail.readUInt32LE(eocd + 16);

  if (directoryOffset === 0xffffffff || entryCount === 0xffff) {
    const locator = tail.lastIndexOf(Buffer.from([0x50, 0x4b, 0x06, 0x07]));
    if (locator < 0) throw new Error(`${url}: ZIP64 locator not found`);
    const zip64EocdOffset = readUInt64(tail, locator + 8);
    const record = await fetchRange(
      url,
      zip64EocdOffset,
      zip64EocdOffset + 56 - 1,
    );
    entryCount = readUInt64(record, 32);
    directorySize = readUInt64(record, 40);
    directoryOffset = readUInt64(record, 48);
  }

  const directory = await fetchRange(
    url,
    directoryOffset,
    directoryOffset + directorySize - 1,
  );
  const entries: RemoteZipEntry[] = [];
  let cursor = 0;
  for (let index = 0; index < entryCount; index += 1) {
    if (directory.readUInt32LE(cursor) !== 0x02014b50) {
      throw new Error(`${url}: bad central directory entry ${index}`);
    }
    const method = directory.readUInt16LE(cursor + 10);
    let compressedSize = directory.readUInt32LE(cursor + 20);
    let uncompressedSize = directory.readUInt32LE(cursor + 24);
    const nameLength = directory.readUInt16LE(cursor + 28);
    const extraLength = directory.readUInt16LE(cursor + 30);
    const commentLength = directory.readUInt16LE(cursor + 32);
    let localHeaderOffset = directory.readUInt32LE(cursor + 42);
    const name = directory.toString(
      "utf8",
      cursor + 46,
      cursor + 46 + nameLength,
    );

    // ZIP64 extra field (0x0001) carries whichever fields overflowed, in
    // this fixed order.
    let extra = cursor + 46 + nameLength;
    const extraEnd = extra + extraLength;
    while (extra + 4 <= extraEnd) {
      const id = directory.readUInt16LE(extra);
      const length = directory.readUInt16LE(extra + 2);
      if (id === 0x0001) {
        let field = extra + 4;
        if (uncompressedSize === 0xffffffff) {
          uncompressedSize = readUInt64(directory, field);
          field += 8;
        }
        if (compressedSize === 0xffffffff) {
          compressedSize = readUInt64(directory, field);
          field += 8;
        }
        if (localHeaderOffset === 0xffffffff) {
          localHeaderOffset = readUInt64(directory, field);
        }
      }
      extra += 4 + length;
    }

    entries.push({
      name,
      method,
      compressedSize,
      uncompressedSize,
      localHeaderOffset,
    });
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

export async function readRemoteZipEntry(
  url: string,
  entry: RemoteZipEntry,
): Promise<Buffer> {
  const header = await fetchRange(
    url,
    entry.localHeaderOffset,
    entry.localHeaderOffset + 30 - 1,
  );
  if (header.readUInt32LE(0) !== 0x04034b50) {
    throw new Error(`${url}: bad local header for ${entry.name}`);
  }
  const dataStart =
    entry.localHeaderOffset +
    30 +
    header.readUInt16LE(26) +
    header.readUInt16LE(28);
  const data = await fetchRange(
    url,
    dataStart,
    dataStart + entry.compressedSize - 1,
  );
  if (entry.method === 0) return data;
  if (entry.method === 8) return inflateRawSync(data);
  throw new Error(
    `${entry.name}: unsupported compression method ${entry.method}`,
  );
}
