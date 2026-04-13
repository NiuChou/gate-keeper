/** @type {import('next').NextConfig} */
const nextConfig = {
  async rewrites() {
    return [
      {
        source: "/svc/:path*",
        destination: "http://backend:8000/svc/:path*",
      },
      {
        source: "/api/auth/:path*",
        destination: "http://auth-service:3001/api/auth/:path*",
      },
    ];
  },
};

module.exports = nextConfig;
