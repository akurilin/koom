import { redirect } from "next/navigation";
/**
 * Legacy route kept as a compatibility redirect for existing
 * bookmarks. The canonical admin recordings page now lives at `/`.
 */
export default function LegacyRecordingsPage() {
  redirect("/");
}
