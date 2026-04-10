/**
 * End-to-end happy-path test for the comment system.
 *
 * Exercises both anonymous and admin commenting flows on the
 * public watch page. Seeds a single recording with a real MP4
 * in R2 so the <video> element can load and provide a duration
 * for the timeline markers.
 *
 * The test is deliberately sequential and self-contained: a
 * single test() block with try/finally cleanup, same pattern
 * as recordings.spec.ts.
 */

import { expect, test } from "@playwright/test";

import {
  cleanupFixtures,
  generateFixtures,
  type FixtureSpec,
} from "./helpers/fixtures";
import {
  cleanupSeeded,
  seedRecordings,
  type SeededRecording,
} from "./helpers/seed";

test.describe.configure({ mode: "serial" });

test("comment system happy path", async ({ page }) => {
  let fixtures: FixtureSpec[] = [];
  let seeded: SeededRecording[] = [];

  const adminSecret = process.env.KOOM_ADMIN_SECRET;
  if (!adminSecret) {
    throw new Error(
      "KOOM_ADMIN_SECRET is not set in the Playwright environment. " +
        "Check that web/.env.test.local exists and was loaded by playwright.config.ts.",
    );
  }

  try {
    // ─── Seed a recording ──────────────────────────────────────
    // Only generate one fixture — we don't need the full three-
    // fixture spread from the recordings test.
    fixtures = await generateFixtures();
    seeded = await seedRecordings(fixtures);

    const recording = seeded[0];
    const watchUrl = `/r/${recording.recordingId}`;

    // ─────────────────────────────────────────────────────────────
    // 1. Navigate to watch page. Verify player + comments pane.
    // ─────────────────────────────────────────────────────────────
    await page.goto(watchUrl);
    await expect(page.getByTestId("video-player")).toBeVisible();
    await expect(page.getByTestId("comments-pane")).toBeVisible();

    // ─────────────────────────────────────────────────────────────
    // 2. Empty state. Wait for the identity fetch to complete
    //    (submit button becomes enabled once koom-commenter cookie
    //    is established via the GET comments endpoint).
    // ─────────────────────────────────────────────────────────────
    await expect(page.getByTestId("no-comments-message")).toBeVisible();

    // Wait for the submit button to be enabled — this means the
    // useEffect GET completed and the koom-commenter cookie is set.
    // We need to type something first so the "empty body" disable
    // doesn't mask the identity check.
    await page.getByTestId("comment-body-input").fill("probe");
    await expect(page.getByTestId("submit-comment-button")).toBeEnabled();
    await page.getByTestId("comment-body-input").clear();

    // ─────────────────────────────────────────────────────────────
    // 3. Post an anonymous comment.
    // ─────────────────────────────────────────────────────────────
    await page.getByTestId("comment-body-input").fill("Great video!");
    // Set the timestamp input to 1 second
    await page.getByTestId("comment-timestamp-input").fill("1");
    await page.getByTestId("submit-comment-button").click();

    // Comment should appear in the list
    const firstComment = page.getByTestId("comment-item").first();
    await expect(firstComment).toBeVisible();
    // Should show "Guest XXXX" display name
    await expect(firstComment).toContainText("Guest");
    await expect(firstComment).toContainText("Great video!");

    // Empty state should be gone
    await expect(page.getByTestId("no-comments-message")).toHaveCount(0);

    // ─────────────────────────────────────────────────────────────
    // 4. Post a second comment at a different timestamp.
    // ─────────────────────────────────────────────────────────────
    await page.getByTestId("comment-body-input").fill("Another thought");
    await page.getByTestId("comment-timestamp-input").fill("0");
    await page.getByTestId("submit-comment-button").click();

    // Two comments visible, sorted by timestamp (0s before 1s)
    const comments = page.getByTestId("comment-item");
    await expect(comments).toHaveCount(2);
    // First comment (by timestamp) should be the 0s one
    await expect(comments.first()).toContainText("Another thought");
    await expect(comments.last()).toContainText("Great video!");

    // ─────────────────────────────────────────────────────────────
    // 5. Timeline markers.
    // ─────────────────────────────────────────────────────────────
    await expect(page.getByTestId("timeline-markers-strip")).toBeVisible();
    await expect(page.getByTestId("timeline-marker")).toHaveCount(2);

    // ─────────────────────────────────────────────────────────────
    // 6. Click a comment's timestamp to seek.
    // ─────────────────────────────────────────────────────────────
    const timestampChip = comments.last().getByTestId("comment-timestamp");
    await timestampChip.click();
    // The video should have seeked. We can verify via the video's
    // currentTime. Playwright can evaluate JS in the page context.
    const currentTime = await page
      .getByTestId("video-player")
      .evaluate((el: HTMLVideoElement) => el.currentTime);
    // Should be close to 1 second (the comment's timestamp)
    expect(currentTime).toBeGreaterThanOrEqual(0.5);

    // ─────────────────────────────────────────────────────────────
    // 7. Self-delete a comment.
    // ─────────────────────────────────────────────────────────────
    // Delete the first comment (the "Another thought" one at 0s).
    // The delete button should be visible on own comments.
    page.once("dialog", (dialog) => {
      void dialog.accept();
    });
    await comments.first().getByTestId("delete-comment-button").click();

    // Only 1 comment should remain
    await expect(page.getByTestId("comment-item")).toHaveCount(1);
    await expect(page.getByTestId("comment-item").first()).toContainText(
      "Great video!",
    );

    // ─────────────────────────────────────────────────────────────
    // 8. Admin login then post an admin comment.
    // ─────────────────────────────────────────────────────────────
    // Log in by navigating to /login
    await page.goto("/login");
    await page.getByTestId("admin-secret-input").fill(adminSecret);
    await page.getByTestId("login-button").click();
    // Wait for redirect to recordings page
    await expect(page).toHaveURL(/\/(\?.*)?$/);

    // Go back to the watch page
    await page.goto(watchUrl);
    await expect(page.getByTestId("comments-pane")).toBeVisible();

    // Post an admin comment
    await page.getByTestId("comment-body-input").fill("Thanks for watching!");
    await page.getByTestId("comment-timestamp-input").fill("2");
    await page.getByTestId("submit-comment-button").click();

    // Should see 2 comments now
    await expect(page.getByTestId("comment-item")).toHaveCount(2);

    // The admin comment should have the admin badge
    const adminComment = page
      .getByTestId("comment-item")
      .filter({ hasText: "Thanks for watching!" });
    await expect(adminComment.getByTestId("admin-badge")).toBeVisible();
    await expect(adminComment).toContainText("Admin");

    // ─────────────────────────────────────────────────────────────
    // 9. Admin deletes the anonymous comment.
    // ─────────────────────────────────────────────────────────────
    const anonComment = page
      .getByTestId("comment-item")
      .filter({ hasText: "Great video!" });

    page.once("dialog", (dialog) => {
      void dialog.accept();
    });
    await anonComment.getByTestId("delete-comment-button").click();

    // Only the admin comment remains
    await expect(page.getByTestId("comment-item")).toHaveCount(1);
    await expect(page.getByTestId("comment-item").first()).toContainText(
      "Thanks for watching!",
    );
  } finally {
    await cleanupSeeded(seeded).catch((err) => {
      console.warn("[teardown] cleanupSeeded failed:", err);
    });
    await cleanupFixtures().catch((err) => {
      console.warn("[teardown] cleanupFixtures failed:", err);
    });
  }
});
