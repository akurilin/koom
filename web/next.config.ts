import type { NextConfig } from "next";

const nextConfig: NextConfig = {
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
