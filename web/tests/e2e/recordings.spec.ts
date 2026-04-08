/**
 * End-to-end happy-path test for the admin recordings UI.
 *
 * This is the QA scenario you asked for: a single test that walks
 * the entire user-visible flow from "tries to view recordings while
 * logged out" all the way through to "logs out and is bounced back
 * to login on next attempt." Everything else (vitest integration
 * tests, doctor script) verifies pieces in isolation; this test
 * verifies the whole thing fits together.
 *
 * Test isolation is enforced by the surrounding infrastructure:
 *
 *   - Cloudflare R2 → koom-recordings-test bucket, with a
 *     bucket-scoped S3 token that physically cannot reach the
 *     production koom-recordings bucket.
 *   - Postgres → same local Supabase, but every row this test
 *     creates is namespaced via a generated UUID and removed in
 *     the `finally` block.
 *   - Next.js → spawned by Playwright on port 3456 (or
 *     KOOM_TEST_PORT) with env vars from web/.env.test.local
 *     passed through, so the running app authenticates against
 *     the fake e2e-test admin secret, not the real one.
 *
 * The single test deliberately mirrors the scenario as written
 * end-to-end rather than splitting into many smaller tests.
 * Smaller tests would give nicer failure localization but the
 * setup cost (spinning up the server, generating fixtures,
 * uploading to R2) dominates per-test execution time, so one
 * larger test is the right tradeoff at v1 scale.
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

test("admin recordings happy path", async ({ page }) => {
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
    // Generate fixtures and seed both DB rows and R2 objects so
    // the recordings page has real bytes to render previews from.
    fixtures = await generateFixtures();
    seeded = await seedRecordings(fixtures);

    // Convenience: the three filenames the test seeds. Sorted
    // alphabetically these go a → m → z (matching the file
    // prefixes), and by size they go z → m → a (the longer
    // duration recordings are larger).
    const filenameLong = "koom_e2e_a_long.mp4";
    const filenameMedium = "koom_e2e_m_medium.mp4";
    const filenameShort = "koom_e2e_z_short.mp4";

    // ─────────────────────────────────────────────────────────────
    // 1. Unauthenticated visit to /app/recordings → bounced to
    //    /app/login.
    // ─────────────────────────────────────────────────────────────
    await page.goto("/app/recordings");
    await expect(page).toHaveURL(/\/app\/login(\?.*)?$/);

    // The login form is on screen.
    await expect(page.getByTestId("admin-secret-input")).toBeVisible();
    await expect(page.getByTestId("login-button")).toBeVisible();

    // ─────────────────────────────────────────────────────────────
    // 2. Log in with the test admin secret.
    // ─────────────────────────────────────────────────────────────
    await page.getByTestId("admin-secret-input").fill(adminSecret);
    await page.getByTestId("login-button").click();

    // After successful login the client component does
    // router.replace('/app/recordings'). Wait for the navigation
    // and the page header to appear.
    await expect(page).toHaveURL(/\/app\/recordings(\?.*)?$/);
    await expect(page.getByTestId("recordings-header")).toBeVisible();

    // ─────────────────────────────────────────────────────────────
    // 3. The three seeded cards are visible (alongside whatever
    //    other recordings happen to live in the test DB).
    // ─────────────────────────────────────────────────────────────
    const longCard = cardForFilename(page, filenameLong);
    const mediumCard = cardForFilename(page, filenameMedium);
    const shortCard = cardForFilename(page, filenameShort);

    await expect(longCard).toBeVisible();
    await expect(mediumCard).toBeVisible();
    await expect(shortCard).toBeVisible();

    // ─────────────────────────────────────────────────────────────
    // 4. Sort by name ascending → our three rows should appear in
    //    alphabetical order: a_long, m_medium, z_short.
    // ─────────────────────────────────────────────────────────────
    await page.getByTestId("sort-select").selectOption("name-asc");
    const orderAfterNameAsc = await ourFilenamesInOrder(page, [
      filenameLong,
      filenameMedium,
      filenameShort,
    ]);
    expect(orderAfterNameAsc).toEqual([
      filenameLong,
      filenameMedium,
      filenameShort,
    ]);

    // Sort by name descending → reverse.
    await page.getByTestId("sort-select").selectOption("name-desc");
    const orderAfterNameDesc = await ourFilenamesInOrder(page, [
      filenameLong,
      filenameMedium,
      filenameShort,
    ]);
    expect(orderAfterNameDesc).toEqual([
      filenameShort,
      filenameMedium,
      filenameLong,
    ]);

    // ─────────────────────────────────────────────────────────────
    // 5. Open one recording → land on /r/[id], then go back.
    // ─────────────────────────────────────────────────────────────
    await mediumCard.getByTestId("watch-link").first().click();
    await expect(page).toHaveURL(/\/r\/[0-9a-f-]+(\?.*)?$/);

    await page.goBack();
    await expect(page).toHaveURL(/\/app\/recordings(\?.*)?$/);
    await expect(page.getByTestId("recordings-header")).toBeVisible();

    // ─────────────────────────────────────────────────────────────
    // 6. Delete one recording. Auto-accept the window.confirm()
    //    dialog the page raises, then verify the card disappears.
    // ─────────────────────────────────────────────────────────────
    page.once("dialog", (dialog) => {
      void dialog.accept();
    });

    const cardToDelete = cardForFilename(page, filenameMedium);
    await cardToDelete.getByTestId("delete-button").click();

    // Card disappears from the DOM (state update + re-render).
    await expect(cardToDelete).toHaveCount(0);

    // Mark this seeded recording as gone so cleanupSeeded doesn't
    // try to delete it twice.
    seeded = seeded.filter((r) => r.originalFilename !== filenameMedium);

    // The other two are still there.
    await expect(cardForFilename(page, filenameLong)).toBeVisible();
    await expect(cardForFilename(page, filenameShort)).toBeVisible();

    // ─────────────────────────────────────────────────────────────
    // 7. Log out → bounced back to /app/login.
    // ─────────────────────────────────────────────────────────────
    await page.getByTestId("logout-button").click();
    await expect(page).toHaveURL(/\/app\/login(\?.*)?$/);

    // ─────────────────────────────────────────────────────────────
    // 8. Try to visit /app/recordings again → bounced to login.
    // ─────────────────────────────────────────────────────────────
    await page.goto("/app/recordings");
    await expect(page).toHaveURL(/\/app\/login(\?.*)?$/);
  } finally {
    await cleanupSeeded(seeded).catch((err) => {
      console.warn("[teardown] cleanupSeeded failed:", err);
    });
    await cleanupFixtures().catch((err) => {
      console.warn("[teardown] cleanupFixtures failed:", err);
    });
  }
});

// ────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────

/**
 * Locator for a single recording card identified by its rendered
 * filename. The recordings list may contain other rows alongside
 * the seeded ones (the test DB is shared with the vitest suite),
 * so we can't reliably address cards by index.
 */
function cardForFilename(
  page: import("@playwright/test").Page,
  filename: string,
) {
  return page
    .getByTestId("recording-card")
    .filter({ has: page.getByTestId("filename").getByText(filename) });
}

/**
 * Read the list of recording cards in DOM order, then return the
 * subset whose filename matches one of the seeded filenames. Used
 * to assert sort orderings without depending on the rest of the
 * recordings the test DB might contain.
 */
async function ourFilenamesInOrder(
  page: import("@playwright/test").Page,
  ours: string[],
): Promise<string[]> {
  const filenames = await page
    .getByTestId("recording-card")
    .locator('[data-testid="filename"]')
    .allTextContents();
  const ourSet = new Set(ours);
  return filenames.filter((f) => ourSet.has(f));
}
