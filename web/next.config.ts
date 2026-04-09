import type { NextConfig } from "next";

const r2PublicBaseUrl = process.env.R2_PUBLIC_BASE_URL;
const r2RemotePatterns: NonNullable<NextConfig["images"]>["remotePatterns"] =
  [];

if (r2PublicBaseUrl) {
  const url = new URL(r2PublicBaseUrl);
  const normalizedPathname = `${url.pathname.replace(/\/$/, "")}/**`;

  r2RemotePatterns.push({
    protocol: url.protocol === "https:" ? "https" : "http",
    hostname: url.hostname,
    port: url.port,
    pathname: normalizedPathname,
  });
}

const nextConfig: NextConfig = {
  images: {
    remotePatterns: r2RemotePatterns,
  },
  // The admin UI at /app/* gates itself on a session cookie and
  // must never be served from the browser's back/forward cache. A
  // cached 307 "redirect to /app/login" from the pre-login visit
  // gets in the way of every subsequent navigation back to
  // /app/recordings and silently breaks the UX. no-store on every
  // admin HTML response is the cheapest fix.
  async headers() {
    return [
      {
        source: "/app/:path*",
        headers: [
          {
            key: "Cache-Control",
            value: "no-store, must-revalidate",
          },
        ],
      },
    ];
  },
};

export default nextConfig;
