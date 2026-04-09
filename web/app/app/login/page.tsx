import { redirect } from "next/navigation";
/**
 * Legacy route kept as a compatibility redirect for existing
 * bookmarks. The canonical admin login page now lives at `/login`.
 */
export default function LegacyLoginPage() {
  redirect("/login");
}
