import { describe, expect, it } from "vitest";

import type { Comment } from "@/lib/db/comments";
import { buildMePayload, serializeComment } from "@/lib/types";

function fakeComment(overrides: Partial<Comment> = {}): Comment {
  return {
    id: "comment-1",
    recordingId: "rec-1",
    commenterId: "guest-aaaa-bbbb",
    isAdmin: false,
    displayName: "Guest aaaa",
    body: "hello",
    timestampSeconds: 12.5,
    createdAt: new Date("2026-04-10T12:00:00Z"),
    ...overrides,
  };
}

describe("serializeComment", () => {
  it("serializes basic fields", () => {
    const comment = fakeComment();
    const result = serializeComment(comment, {
      isAdmin: false,
      commenterId: "other-id",
    });

    expect(result.id).toBe("comment-1");
    expect(result.displayName).toBe("Guest aaaa");
    expect(result.body).toBe("hello");
    expect(result.timestampSeconds).toBe(12.5);
    expect(result.createdAt).toBe("2026-04-10T12:00:00.000Z");
    expect(result.isAdmin).toBe(false);
  });

  describe("isOwn for anonymous comments", () => {
    it("is true when commenter IDs match", () => {
      const comment = fakeComment({ commenterId: "guest-aaaa-bbbb" });
      const result = serializeComment(comment, {
        isAdmin: false,
        commenterId: "guest-aaaa-bbbb",
      });
      expect(result.isOwn).toBe(true);
    });

    it("is false when commenter IDs differ", () => {
      const comment = fakeComment({ commenterId: "guest-aaaa-bbbb" });
      const result = serializeComment(comment, {
        isAdmin: false,
        commenterId: "guest-cccc-dddd",
      });
      expect(result.isOwn).toBe(false);
    });

    it("is false when viewer has no commenter ID", () => {
      const comment = fakeComment({ commenterId: "guest-aaaa-bbbb" });
      const result = serializeComment(comment, {
        isAdmin: false,
        commenterId: null,
      });
      expect(result.isOwn).toBe(false);
    });

    it("is true when viewer is admin (admin can act on any comment)", () => {
      const comment = fakeComment({ commenterId: "guest-aaaa-bbbb" });
      const result = serializeComment(comment, {
        isAdmin: true,
        commenterId: null,
      });
      // Anonymous comment viewed by admin — isOwn is false because
      // the admin didn't author this comment. The UI uses canDelete
      // (from MeData) to control the delete button for admins.
      expect(result.isOwn).toBe(false);
    });
  });

  describe("isOwn for admin comments", () => {
    const adminComment = fakeComment({
      isAdmin: true,
      commenterId: null,
      displayName: "Admin",
    });

    it("is true when viewer is also admin", () => {
      const result = serializeComment(adminComment, {
        isAdmin: true,
        commenterId: null,
      });
      expect(result.isOwn).toBe(true);
    });

    it("is false when viewer is anonymous", () => {
      const result = serializeComment(adminComment, {
        isAdmin: false,
        commenterId: "guest-aaaa-bbbb",
      });
      expect(result.isOwn).toBe(false);
    });
  });
});

describe("buildMePayload", () => {
  it("returns null when viewer has no identity", () => {
    expect(buildMePayload({ isAdmin: false, commenterId: null })).toBeNull();
  });

  it("returns admin payload", () => {
    const me = buildMePayload({ isAdmin: true, commenterId: null });
    expect(me).toEqual({
      kind: "admin",
      displayName: "Admin",
      commenterId: null,
      canDelete: true,
    });
  });

  it("returns anonymous payload with display name from commenter ID", () => {
    const me = buildMePayload({
      isAdmin: false,
      commenterId: "abcd-1234-5678",
    });
    expect(me).toEqual({
      kind: "anonymous",
      displayName: "Guest abcd",
      commenterId: "abcd-1234-5678",
      canDelete: false,
    });
  });

  it("admin takes precedence even if commenterId is present", () => {
    const me = buildMePayload({
      isAdmin: true,
      commenterId: "abcd-1234-5678",
    });
    expect(me!.kind).toBe("admin");
    expect(me!.displayName).toBe("Admin");
    expect(me!.commenterId).toBeNull();
    expect(me!.canDelete).toBe(true);
  });
});
