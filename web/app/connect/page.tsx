/**
 * /connect?state=...&device=... — desktop app sign-in confirmation.
 *
 * The desktop app opens this page in an ASWebAuthenticationSession.
 * If the browser isn't signed in yet, it's sent through Google
 * sign-in first and returned here. The admin then confirms, which
 * POSTs to /api/admin/device-tokens; that mints a token for this
 * device and redirects to koom://auth-callback, handing the token
 * back to the app. "Cancel" returns to the app without a token.
 */

import { redirect } from "next/navigation";
import type { ReactElement } from "react";

import {
  desktopCallbackUrl,
  isValidDeviceState,
  normalizeDeviceLabel,
} from "@/lib/auth/device-tokens";
import { currentAdminEmail } from "@/lib/auth/session";

export const dynamic = "force-dynamic";

export default async function ConnectPage(props: {
  searchParams: Promise<{ state?: string; device?: string }>;
}): Promise<ReactElement> {
  const { state, device } = await props.searchParams;

  if (!isValidDeviceState(state ?? null)) {
    return (
      <main className="min-h-screen flex items-center justify-center px-4">
        <p className="text-sm text-zinc-500 dark:text-zinc-400">
          This sign-in link is invalid. Start again from koom&apos;s Settings.
        </p>
      </main>
    );
  }

  const email = await currentAdminEmail();
  if (!email) {
    const here = `/connect?${new URLSearchParams({
      state: state!,
      device: device ?? "",
    }).toString()}`;
    redirect(`/login?next=${encodeURIComponent(here)}`);
  }

  const label = normalizeDeviceLabel(device);

  return (
    <main className="min-h-screen flex items-center justify-center px-4">
      <div className="w-full max-w-sm space-y-6 text-center">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">
            Connect koom
          </h1>
          <p className="mt-2 text-sm text-zinc-500 dark:text-zinc-400">
            Allow <span className="font-medium">{label}</span> to upload
            recordings as <span className="font-medium">{email}</span>?
          </p>
        </div>

        <form method="post" action="/api/admin/device-tokens">
          <input type="hidden" name="state" value={state} />
          <input type="hidden" name="device" value={label} />
          <button
            type="submit"
            data-testid="connect-device"
            className="w-full rounded-md bg-sky-600 px-4 py-2 text-sm font-medium text-white shadow hover:bg-sky-500"
          >
            Connect {label}
          </button>
        </form>

        <a
          href={desktopCallbackUrl({ state: state!, error: "cancelled" })}
          className="block text-sm text-zinc-500 hover:text-zinc-700 dark:text-zinc-400 dark:hover:text-zinc-200"
        >
          Cancel
        </a>
      </div>
    </main>
  );
}
