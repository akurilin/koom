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
  // The admin UI at / and /login gates itself on a session cookie and
  // must never be served from the browser's back/forward cache. A
  // cached 307 "redirect to /login" from the pre-login visit gets in
  // the way of subsequent navigation back to / and silently breaks
  // the UX. no-store on every admin HTML response is the cheapest fix.
  async headers() {
    return [
      {
        source: "/",
        headers: [
          {
            key: "Cache-Control",
            value: "no-store, must-revalidate",
          },
        ],
      },
      {
        source: "/login",
        headers: [
          {
            key: "Cache-Control",
            value: "no-store, must-revalidate",
          },
        ],
      },
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
