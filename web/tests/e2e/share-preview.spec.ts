import { expect, test } from "@playwright/test";

import {
  deleteRecordingThumbnailObject,
  putRecordingThumbnail,
} from "@/lib/r2/client";

import {
  cleanupFixtures,
  generateFixtures,
  generateThumbnailFixture,
} from "./helpers/fixtures";
import {
  cleanupSeeded,
  seedRecordings,
  type SeededRecording,
} from "./helpers/seed";

test("public watch links provide recording previews in the HTML head", async ({
  request,
}) => {
  let seeded: SeededRecording[] = [];
  try {
    const fixtures = await generateFixtures();
    seeded = await seedRecordings(fixtures);
    const [first, second, missing] = seeded;

    for (const [index, recording] of [first, second].entries()) {
      const jpeg = await generateThumbnailFixture(fixtures[index]);
      await putRecordingThumbnail(recording.recordingId, jpeg);
    }

    // Some preview fetchers use a browser user agent and read only the head.
    const userAgents = [
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
      "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)",
      "WhatsApp/2.22.19.78 I",
    ];
    for (const userAgent of userAgents) {
      for (const recording of [first, second]) {
        const response = await request.get(`/r/${recording.recordingId}`, {
          headers: { "User-Agent": userAgent },
        });
        expect(response.ok()).toBeTruthy();
        const head = (await response.text()).split("</head>")[0];
        expect(head).toContain(
          `property="og:title" content="${recording.originalFilename}"`,
        );
        const image = head.match(/property="og:image" content="([^"]+)"/)?.[1];
        expect(image).toContain(
          `/recordings/${recording.recordingId}/thumbnail-v1.jpg`,
        );
        const thumbnail = await request.get(image!);
        expect(thumbnail.ok()).toBeTruthy();
        expect(thumbnail.headers()["content-type"]).toBe("image/jpeg");
      }
    }

    const response = await request.get(`/r/${missing.recordingId}`);
    expect(response.ok()).toBeTruthy();
    const head = (await response.text()).split("</head>")[0];
    expect(head).toContain(`rel="apple-touch-icon"`);
    expect(head).not.toContain(`property="og:image"`);
  } finally {
    try {
      await Promise.all(
        seeded.map(({ recordingId }) =>
          deleteRecordingThumbnailObject(recordingId),
        ),
      );
    } finally {
      await cleanupSeeded(seeded);
      await cleanupFixtures();
    }
  }
});
