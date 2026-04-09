import { redirect } from "next/navigation";

/**
 * Legacy namespace redirect. The canonical admin page is now `/`.
 */
export default function LegacyAppIndexPage() {
  redirect("/");
}
